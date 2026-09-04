import XCTest

// The delivery half of paste-on-release: the decisions `VoiceTypeSession` makes
// at the moment text lands in the focused app. Driven through the production API
// with the inserter injected, so nothing here posts a real ⌘V into whatever the
// developer has focused or touches the real pasteboard.

@MainActor
private final class RecordingInserter: VoiceTypeTextInserter {
  var inserted: [String] = []
  var caretFollowsWord = false
  var frontmost: String?
  var outcome: VoiceTypeInsertion = .pasted

  func insert(_ text: String) -> VoiceTypeInsertion {
    inserted.append(text)
    return outcome
  }

  func caretFollowsWordCharacter() -> Bool { caretFollowsWord }
  func frontmostBundleIdentifier() -> String? { frontmost }
}

/// One recorded `recordFallback` call, as the shared telemetry contract shapes
/// it.
private struct RecordedFallback: Equatable {
  let from: String
  let to: String
  let reason: String
}

@MainActor
final class VoiceTypeSessionTests: XCTestCase {

  private var inserter = RecordingInserter()
  private var fallbacks: [RecordedFallback] = []

  private func makeSession(accessibilityTrusted: Bool = true) -> VoiceTypeSession {
    inserter = RecordingInserter()
    fallbacks = []
    return VoiceTypeSession(
      inserter: inserter,
      isAccessibilityTrusted: { accessibilityTrusted },
      selfBundleIdentifier: "com.omi.computer-macos",
      recordFallback: { [self] from, to, reason in
        fallbacks.append(RecordedFallback(from: from, to: to, reason: reason))
      })
  }

  func testDeliversTheWholeDictationInOneInsertion() {
    let session = makeSession()
    XCTAssertEqual(session.deliver(payload: "ship it today"), .typed("ship it today"))
    XCTAssertEqual(inserter.inserted, ["ship it today"])
    XCTAssertEqual(session.deliveredCount, "ship it today".count)
    XCTAssertTrue(fallbacks.isEmpty)
  }

  /// A second dictation into the same line landed flush against the first
  /// ("voiceI think") because nothing knew what the caret was sitting after.
  func testASeparatingSpaceGoesInWhenTheCaretFollowsAWord() {
    let session = makeSession()
    inserter.caretFollowsWord = true
    let completion = session.deliver(payload: "I think so")
    XCTAssertEqual(inserter.inserted, [" I think so"])
    // The space is on screen but is not part of what the user dictated, so it
    // must not reach the journal.
    XCTAssertEqual(completion, .typed("I think so"))
    XCTAssertEqual(session.deliveredCount, "I think so".count)
  }

  func testNoSeparatorAtTheStartOfALine() {
    let session = makeSession()
    inserter.caretFollowsWord = false
    _ = session.deliver(payload: "I think so")
    XCTAssertEqual(inserter.inserted, ["I think so"])
  }

  func testWithoutAccessibilityNothingIsDeliveredAndTheTurnGoesToChat() {
    let session = makeSession(accessibilityTrusted: false)
    XCTAssertFalse(session.canDeliver())
    XCTAssertEqual(session.deliver(payload: "ship it"), .none)
    XCTAssertTrue(inserter.inserted.isEmpty)
    XCTAssertEqual(
      fallbacks, [RecordedFallback(from: "keystroke_injection", to: "chat_query", reason: "policy")])
  }

  /// A dock click mid-hold brought Omi forward and the dictation rewrote text
  /// inside Omi's own chat composer.
  func testADictationIsNeverPastedIntoOmiItself() {
    let session = makeSession()
    inserter.frontmost = "com.omi.computer-macos"
    XCTAssertEqual(session.deliver(payload: "ship it"), .none)
    XCTAssertTrue(inserter.inserted.isEmpty)
    XCTAssertEqual(
      fallbacks, [RecordedFallback(from: "keystroke_injection", to: "discarded", reason: "policy")])
  }

  func testAnotherAppInFrontIsDeliveredNormally() {
    let session = makeSession()
    inserter.frontmost = "com.apple.TextEdit"
    XCTAssertEqual(session.deliver(payload: "ship it"), .typed("ship it"))
    XCTAssertEqual(inserter.inserted, ["ship it"])
  }

  /// A dictation the user already spoke should not be lost to a pasteboard
  /// another process has locked — but the degraded mechanism is reported.
  func testAPasteboardRefusalStillDeliversAndReportsTheFallback() {
    let session = makeSession()
    inserter.outcome = .typed
    XCTAssertEqual(session.deliver(payload: "ship it"), .typed("ship it"))
    XCTAssertEqual(
      fallbacks,
      [RecordedFallback(from: "pasteboard_insert", to: "keystroke_injection", reason: "other")])
  }

  func testAFailedInsertionReportsAndDeliversNothing() {
    let session = makeSession()
    inserter.outcome = .failed
    XCTAssertEqual(session.deliver(payload: "ship it"), .none)
    XCTAssertEqual(session.deliveredCount, 0)
    XCTAssertEqual(
      fallbacks, [RecordedFallback(from: "keystroke_injection", to: "discarded", reason: "other")])
  }

  func testAnEmptyDictationTouchesNothing() {
    let session = makeSession()
    XCTAssertEqual(session.deliver(payload: "   \n "), .none)
    XCTAssertTrue(inserter.inserted.isEmpty)
    XCTAssertTrue(fallbacks.isEmpty)
  }

  /// One insertion, whatever the length: the cost of delivery no longer grows
  /// with how long the user held the key.
  func testALongDictationIsStillOneInsertion() {
    let session = makeSession()
    let long = Array(repeating: "word", count: 400).joined(separator: " ")
    XCTAssertEqual(session.deliver(payload: long), .typed(long))
    XCTAssertEqual(inserter.inserted.count, 1)
  }
}
