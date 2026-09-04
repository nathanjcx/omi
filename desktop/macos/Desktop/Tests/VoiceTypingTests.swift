import XCTest

@testable import Omi_Computer

final class VoiceTypeCommandParserTests: XCTestCase {

  func testWakeWordFollowedByTextDictatesTheRemainder() {
    XCTAssertEqual(
      VoiceTypeCommandParser.decide("Type hello world"),
      .typing(payload: "Hello world"))
    XCTAssertEqual(
      VoiceTypeCommandParser.decide("type, hello world"),
      .typing(payload: "Hello world"))
    XCTAssertEqual(
      VoiceTypeCommandParser.decide("Type: meeting notes for Q3."),
      .typing(payload: "Meeting notes for Q3."))
  }

  func testDictatedTextOpensWithACapital() {
    // Dictation starts a sentence; the recognizer hears the first word mid-utterance
    // and lowercases it.
    XCTAssertEqual(VoiceTypeCommandParser.decide("type hello"), .typing(payload: "Hello"))
    // An already-capitalized word (a name) is left exactly as heard.
    XCTAssertEqual(VoiceTypeCommandParser.decide("type Nathan is here"), .typing(payload: "Nathan is here"))
  }

  func testGrowingPrefixOfTheWakeWordIsUndecided() {
    // The first interim fragments of "Type hello" must not be rejected as chat,
    // or the turn is routed before the user has finished the first word.
    for fragment in ["T", "Ty", "typ", "type", "type o", "Type th"] {
      XCTAssertEqual(
        VoiceTypeCommandParser.decide(fragment), .undecided,
        "\(fragment) should still be undecided")
    }
  }

  func testWakeWordAsAPrefixOfALongerWordIsNotACommand() {
    // The regression this guards: "type" inside an ordinary question hijacking
    // the turn and dictating the question into the user's editor.
    XCTAssertEqual(VoiceTypeCommandParser.decide("typescript generics, explain"), .rejected)
    XCTAssertEqual(VoiceTypeCommandParser.decide("typing indicator is broken"), .rejected)
    XCTAssertEqual(VoiceTypeCommandParser.decide("what type of bird is this"), .rejected)
  }

  func testLongerWakeWordWinsOverItsOwnPrefix() {
    XCTAssertEqual(
      VoiceTypeCommandParser.decide("type out the address"),
      .typing(payload: "The address"))
    XCTAssertEqual(
      VoiceTypeCommandParser.decide("type this: buy milk"),
      .typing(payload: "Buy milk"))
  }
}

final class VoiceTypeStreamPlannerTests: XCTestCase {

  func testPureGrowthOnlyInsertsTheNewSuffix() {
    var planner = VoiceTypeStreamPlanner()
    XCTAssertEqual(planner.plan(for: "hello"), .init(backspaces: 0, insertion: "hello"))
    XCTAssertEqual(planner.plan(for: "hello wor"), .init(backspaces: 0, insertion: " wor"))
    XCTAssertEqual(planner.plan(for: "hello world"), .init(backspaces: 0, insertion: "ld"))
    XCTAssertEqual(planner.typed, "hello world")
  }

  func testRevisedTailRewritesOnlyTheDivergentPart() {
    // ASR revises "wright" to "write". Typing only appended text would leave the
    // wrong word on screen for good.
    var planner = VoiceTypeStreamPlanner()
    _ = planner.plan(for: "I wright")
    // "I wri" survives; only "ght" is deleted.
    XCTAssertEqual(planner.plan(for: "I write"), .init(backspaces: 3, insertion: "te"))
    XCTAssertEqual(planner.typed, "I write")
  }

  func testUnchangedTranscriptEmitsNothing() {
    var planner = VoiceTypeStreamPlanner()
    _ = planner.plan(for: "same")
    XCTAssertTrue(planner.plan(for: "same").isEmpty)
  }

  func testResetForgetsTheTurnWithoutProposingDeletions() {
    var planner = VoiceTypeStreamPlanner()
    _ = planner.plan(for: "first turn")
    planner.reset()
    // The next turn must never delete the previous turn's text.
    XCTAssertEqual(planner.plan(for: "second"), .init(backspaces: 0, insertion: "second"))
  }
}

@MainActor
final class VoiceTypeSessionTests: XCTestCase {

  private final class RecordingSink: KeystrokeSink {
    private(set) var typed = ""
    private(set) var deletions: [Int] = []

    func deleteBackward(_ count: Int) {
      guard count > 0 else { return }
      deletions.append(count)
      typed.removeLast(min(count, typed.count))
    }

    func insert(_ text: String) {
      typed += text
    }
  }

  private func makeSession(trusted: Bool = true) -> (VoiceTypeSession, RecordingSink) {
    let sink = RecordingSink()
    return (VoiceTypeSession(sink: sink, isAccessibilityTrusted: { trusted }), sink)
  }

  func testDictatesStreamedTextAndClaimsTheTurn() {
    let (session, sink) = makeSession()
    session.begin()
    XCTAssertFalse(
      session.update(transcript: "Type"),
      "the bare wake word types nothing, so it has not taken the turn from chat yet")
    XCTAssertEqual(sink.typed, "")
    XCTAssertFalse(session.update(transcript: "Type hello"))
    XCTAssertTrue(session.update(transcript: "Type hello there"))
    XCTAssertEqual(sink.typed, "Hello", "the moving last word waits one probe")
    XCTAssertEqual(session.finish(transcript: "Type hello there"), .typed("Hello there"))
    XCTAssertEqual(sink.typed, "Hello there")
    XCTAssertEqual(sink.deletions, [], "a smooth turn never rewrites what it typed")
  }

  func testOrdinaryQuestionIsLeftToChatAndTypesNothing() {
    let (session, sink) = makeSession()
    session.begin()
    XCTAssertFalse(session.update(transcript: "what is on my calendar"))
    XCTAssertEqual(session.finish(transcript: "what is on my calendar"), .none)
    XCTAssertEqual(sink.typed, "")
  }

  func testFinalTranscriptCorrectionRewritesWhatWasAlreadyTyped() {
    let (session, sink) = makeSession()
    session.begin()
    session.update(transcript: "Type send it to nate")
    session.update(transcript: "Type send it to nate")
    // The contextual corrector fixes the name only on the final transcript.
    XCTAssertEqual(session.finish(transcript: "Type send it to Nathan"), .typed("Send it to Nathan"))
    XCTAssertEqual(sink.typed, "Send it to Nathan")
  }

  func testTurnStaysWithTypingOnceArmedEvenIfLaterTextLooksLikeAQuestion() {
    let (session, sink) = makeSession()
    session.begin()
    XCTAssertFalse(
      session.update(transcript: "Type what is on my calendar"),
      "the first decode of a turn has nothing to agree with yet")
    XCTAssertTrue(session.update(transcript: "Type what is on my calendar"))
    XCTAssertEqual(
      session.finish(transcript: "Type what is on my calendar"),
      .typed("What is on my calendar"))
    XCTAssertEqual(sink.typed, "What is on my calendar")
  }

  func testWithoutAccessibilityTheTurnIsReleasedToChatRatherThanSwallowed() {
    // Fail-open: the words still reach Omi instead of disappearing into a
    // keystroke sink the app is not allowed to use.
    let (session, sink) = makeSession(trusted: false)
    session.begin()
    XCTAssertFalse(session.update(transcript: "Type hello"))
    XCTAssertEqual(session.finish(transcript: "Type hello"), .none)
    XCTAssertEqual(sink.typed, "")
  }

  func testEarlyFragmentDoesNotDisableTypingForTheRestOfTheTurn() {
    // The bug this guards, observed live: the first on-device decode of a hold
    // is one or two characters of a half-spoken word. Treating that as "not a
    // type command" latched the turn to chat before the user had finished
    // saying "Type", which silently disabled the feature on every real turn.
    let (session, sink) = makeSession()
    session.begin()
    XCTAssertFalse(session.update(transcript: "So"))
    XCTAssertFalse(session.update(transcript: "Ty"))
    XCTAssertFalse(session.update(transcript: "Type hello"))
    XCTAssertEqual(session.finish(transcript: "Type hello there"), .typed("Hello there"))
    XCTAssertEqual(sink.typed, "Hello there")
  }

  func testANewTurnNeverDeletesThePreviousTurnsText() {
    let (session, sink) = makeSession()
    session.begin()
    session.update(transcript: "Type first")
    _ = session.finish(transcript: "Type first")
    session.begin()
    session.update(transcript: "Type second")
    _ = session.finish(transcript: "Type second")
    XCTAssertEqual(sink.typed, "FirstSecond")
    XCTAssertEqual(sink.deletions, [])
  }

  func testCompletionCarriesExactlyWhatReachedTheFocusedApp() {
    // The chat record says "Typed: <text>", so the completion has to report the
    // text that actually landed — not the raw utterance, which still carries the
    // "Type" wake word the user never meant to dictate.
    let (session, sink) = makeSession()
    session.begin()
    session.update(transcript: "Type hello there")
    let completion = session.finish(transcript: "Type hello there")
    XCTAssertEqual(completion, .typed("Hello there"))
    XCTAssertEqual(completion, .typed(sink.typed))
  }

  func testAFlushedTurnReportsTheWholeSentenceNotJustTheProbedPrefix() {
    // The closing decode arrives after the key is up. Journaling what the probes
    // had delivered at key-up would record a truncated sentence.
    let (session, _) = makeSession()
    session.begin()
    session.update(transcript: "Type hello")
    session.update(transcript: "Type hello")
    let token = session.beginFlush()
    XCTAssertEqual(
      session.endFlush(token: token, finalTranscript: "Type hello there friend"),
      .typed("Hello there friend"))
  }

  func testATurnThatNeverDictatedReportsNothingToJournal() {
    let (session, _) = makeSession()
    session.begin()
    session.update(transcript: "what is on my calendar")
    let token = session.beginFlush()
    XCTAssertEqual(
      session.endFlush(token: token, finalTranscript: "what is on my calendar"), .none)
  }

  func testAStaleFlushReportsNothingSoItCannotJournalIntoTheNextTurn() {
    let (session, _) = makeSession()
    session.begin()
    session.update(transcript: "Type first")
    let stale = session.beginFlush()
    session.begin()
    XCTAssertEqual(session.endFlush(token: stale, finalTranscript: "Type first"), .none)
  }
}

final class VoiceTypeAudioTrimTests: XCTestCase {

  private func pcm(_ samples: [Int16]) -> Data {
    var copy = samples.map { $0.littleEndian }
    return copy.withUnsafeMutableBufferPointer { Data(buffer: $0) }
  }

  func testLeadingSilenceIsDroppedBeforeTheFirstSpeech() {
    // A locked hold starts when the key is tapped, not when the user speaks.
    // Live, 9s of room tone decoded as 43 characters of invented words.
    let silence = [Int16](repeating: 0, count: 16_000)
    let speech = (0..<16_000).map { Int16(truncatingIfNeeded: ($0 % 2 == 0 ? 6_000 : -6_000)) }
    let trimmed = VoiceTypeAudioTrim.trimmingLeadingSilence(pcm(silence + speech))
    let trimmedSamples = trimmed.count / 2
    // The speech survives, plus at most the 100ms pre-roll in front of it.
    XCTAssertGreaterThanOrEqual(trimmedSamples, 16_000)
    XCTAssertLessThanOrEqual(trimmedSamples, 16_000 + 1_600)
  }

  func testAnEntirelyQuietBufferTrimsToNothing() {
    let quiet = [Int16](repeating: 3, count: 32_000)
    XCTAssertTrue(VoiceTypeAudioTrim.trimmingLeadingSilence(pcm(quiet)).isEmpty)
  }

  func testSpeechFromTheFirstSampleIsKeptWhole() {
    let speech = (0..<16_000).map { Int16(truncatingIfNeeded: ($0 % 2 == 0 ? 6_000 : -6_000)) }
    XCTAssertEqual(VoiceTypeAudioTrim.trimmingLeadingSilence(pcm(speech)).count, 32_000)
  }
}

final class VoiceTypeStabilizerTests: XCTestCase {

  func testAWordStillBeingSpelledIsHeldBack() {
    // The bug this guards: typing the decoder's moving edge and rewriting it a
    // probe later, which reads as flicker.
    var stabilizer = VoiceTypeStabilizer()
    _ = stabilizer.stabilized("type hell")
    XCTAssertEqual(stabilizer.stabilized("type hello"), "type ")
  }

  func testWholeWordsAreReleasedWithoutWaitingAnotherProbe() {
    var stabilizer = VoiceTypeStabilizer()
    _ = stabilizer.stabilized("type hello")
    // The newer decode continues with a space, so "hello" is settled — holding
    // it back another probe would cost a word of latency and buy nothing.
    XCTAssertEqual(stabilizer.stabilized("type hello there"), "type hello")
  }

  func testAnUnchangedDecodeReleasesInFull() {
    // A pause in speech should let the text catch up completely.
    var stabilizer = VoiceTypeStabilizer()
    _ = stabilizer.stabilized("type hello there")
    XCTAssertEqual(stabilizer.stabilized("type hello there"), "type hello there")
  }

  func testARevisedEarlierWordIsNotReleasedAsIfAgreed() {
    var stabilizer = VoiceTypeStabilizer()
    _ = stabilizer.stabilized("type wright it down")
    XCTAssertEqual(stabilizer.stabilized("type write it down"), "type ")
  }

  func testSettleReleasesTheClosingTranscriptWhole() {
    var stabilizer = VoiceTypeStabilizer()
    _ = stabilizer.stabilized("type hello th")
    XCTAssertEqual(stabilizer.settle("type hello there"), "type hello there")
  }
}
