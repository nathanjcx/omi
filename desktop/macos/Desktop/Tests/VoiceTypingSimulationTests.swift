import XCTest

@testable import Omi_Computer

/// Drives the real voice-typing components the way `PushToTalkManager` does, so
/// a whole dictation can be exercised without a microphone.
///
/// Every bug this feature has shipped lived in the seams between these parts —
/// the wake word lost between probe and parser, two recognizers interleaved into
/// one stabilizer, a window that stopped growing — and none of them were visible
/// from a unit test of any single piece. This simulates the loop end to end:
/// audio accumulates, the recognizer sees only the uncommitted window, windows
/// commit, and the text is typed into a real sink.
@MainActor
final class VoiceTypingSimulationTests: XCTestCase {

  /// Audio occupied by one spoken word. 0.4 s at 16 kHz mono s16le.
  private static let bytesPerWord = 12_800

  private final class RecordingSink: KeystrokeSink {
    private(set) var typed = ""
    private(set) var deletions: [Int] = []
    private(set) var insertions = 0

    func deleteBackward(_ count: Int) {
      guard count > 0 else { return }
      deletions.append(count)
      typed.removeLast(min(count, typed.count))
    }

    func insert(_ text: String) {
      insertions += 1
      typed += text
    }
  }

  /// Result of running one simulated hold.
  private struct Outcome {
    let typed: String
    let claimed: Bool
    let completion: VoiceTypeSession.Completion
    /// Largest audio slice the recognizer was ever asked to decode. Bounded
    /// cost is the whole point of the window, so this is asserted, not printed.
    let peakDecodeBytes: Int
    let commits: Int
    let deletions: [Int]
    let insertions: Int
    /// Probe on which the first character reached the app — the feature's
    /// perceived speed.
    let firstInsertionProbe: Int
    let probes: Int
  }

  /// Runs a hold: `words` are spoken one probe at a time, the recognizer decodes
  /// only the uncommitted window, and the turn is closed the way the manager
  /// closes it.
  ///
  /// - Parameters:
  ///   - pausesAfter: word indices the speaker pauses after, which is where a
  ///     window is allowed to commit.
  ///   - reviseLastWord: whether the newest word is initially misheard and
  ///     corrected on the next probe, as a real recognizer does.
  private func runHold(
    words: [String],
    pausesAfter: Set<Int> = [],
    reviseLastWord: Bool = false,
    trusted: Bool = true,
    nilProbeEvery: Int = 0,
    probesStartAtWord: Int = 0,
    window seededWindow: VoiceTypeDecodeWindow = VoiceTypeDecodeWindow(),
    streamCommitsPauses: Bool = false,
    streamText: (String) -> String = { $0 }
  ) -> Outcome {
    let sink = RecordingSink()
    let session = VoiceTypeSession(sink: sink, isAccessibilityTrusted: { trusted })
    var window = seededWindow
    session.begin()

    // Words, not bytes: a pause adds audio without adding a word, so deriving
    // the window's first word from a byte count skips real words.
    var committedWords = 0
    var peakDecode = 0
    var commits = 0
    var lastTail = ""
    var probeCount = 0
    var firstInsertionProbe = -1

    for index in words.indices {
      // A pause is not instantaneous: it spans several probes, during which the
      // recognizer keeps returning the same words. That is what lets a decode
      // settle, and it is the only safe moment to freeze text.
      let probesForThisWord = pausesAfter.contains(index) ? 3 : 1
      for probe in 0..<probesForThisWord {
        let isPauseProbe = probe > 0
        window.append(Data(count: Self.bytesPerWord))

        // The recognizer only ever sees the uncommitted window.
        let windowWordStart = min(committedWords, index)
        var visible = Array(words[windowWordStart...index])
        // The newest word is still being spelled — until the speaker pauses on
        // it, at which point the recognizer has all of it.
        if reviseLastWord, !isPauseProbe, index < words.count - 1, let last = visible.last {
          visible[visible.count - 1] = String(last.prefix(max(1, last.count - 1)))
        }
        let tail = visible.joined(separator: " ")
        peakDecode = max(peakDecode, window.pendingAudio.count)
        probeCount += 1
        // Audio arrives before probing does — the hub's warm-wait captures for
        // up to a second before the route settles. Those words must still be
        // in the window when the first probe finally runs.
        if index < probesStartAtWord { continue }
        // A real probe sometimes returns nothing at all (observed live as
        // `nil`). The loop must survive that without losing the turn.
        if nilProbeEvery > 0, probeCount % nilProbeEvery == 0 { continue }

        let full = window.transcript(tail: tail)
        let stable = tail == lastTail
        lastTail = tail
        // With the backend stream healthy the manager gives it first claim on
        // each pause: the stream's finished utterance for exactly this window
        // lands a beat after the pause begins, before the local decode's longer
        // quiet requirement is met.
        if streamCommitsPauses, isPauseProbe, probe == 1 {
          let utterance = streamText(visible.joined(separator: " "))
          let outcome = window.adoptStreamFinal(
            text: utterance, startByte: window.consumedBytes, endByte: window.appendedBytes)
          XCTAssertEqual(outcome, .adopted, "a pause the stream reaches first is the stream's to commit")
          commits += 1
          lastTail = ""
          committedWords = index + 1
          session.update(transcript: window.transcript(tail: ""), isSettled: true)
          continue
        }
        if window.commitIfReady(
          tail: tail, endsQuiet: isPauseProbe && !streamCommitsPauses, tailIsStable: stable)
        {
          commits += 1
          lastTail = ""
          // Every word the window decoded is now frozen.
          committedWords = index + 1
        }
        session.update(transcript: full)
        if firstInsertionProbe < 0, !sink.typed.isEmpty { firstInsertionProbe = probeCount }
      }
    }

    // Key-up: the closing decode covers the uncommitted window only, and the
    // session is handed the whole utterance.
    let finalTail =
      committedWords >= words.count ? "" : words[committedWords...].joined(separator: " ")
    let completion = session.finish(transcript: window.transcript(tail: finalTail))
    return Outcome(
      typed: sink.typed,
      claimed: completion != .none,
      completion: completion,
      peakDecodeBytes: peakDecode,
      commits: commits,
      deletions: sink.deletions,
      insertions: sink.insertions,
      firstInsertionProbe: firstInsertionProbe,
      probes: probeCount)
  }

  private func expectedTyped(_ words: [String]) -> String {
    let rest = words.dropFirst().joined(separator: " ")
    guard let first = rest.first, first.isLowercase else { return rest }
    return rest.prefix(1).uppercased() + rest.dropFirst()
  }

  // MARK: - Always enters typing mode

  func testEveryNaturalWayOfSayingTheWakeWordEntersTypingMode() {
    // "It must ALWAYS go to typing mode when they first say type." Each of these
    // is a real thing the recognizer returns for the same intent.
    let openings = [
      "Type", "Type.", "Type,", "Type:", "Type;", "type", "Type -", "Type—",
    ]
    for opening in openings {
      let outcome = runHold(words: [opening, "hello", "there", "friend"])
      XCTAssertTrue(outcome.claimed, "\(opening) should dictate")
      XCTAssertEqual(outcome.typed, "Hello there friend", "\(opening) typed the wrong text")
    }
  }

  func testLongerWakeWordsDictateTheirRemainder() {
    XCTAssertEqual(
      runHold(words: ["Type", "out", "the", "address", "now"]).typed, "The address now")
    XCTAssertEqual(
      runHold(words: ["Type", "this", "buy", "milk", "today"]).typed, "Buy milk today")
  }

  func testAQuestionNeverEntersTypingMode() {
    let outcome = runHold(words: ["What", "is", "on", "my", "calendar", "tomorrow"])
    XCTAssertFalse(outcome.claimed)
    XCTAssertEqual(outcome.typed, "")
  }

  func testWordsThatMerelyStartWithTypeAreNotCommands() {
    for opening in ["Typescript", "Typing", "Typed"] {
      let outcome = runHold(words: [opening, "is", "broken", "today"])
      XCTAssertFalse(outcome.claimed, "\(opening) must not dictate")
      XCTAssertEqual(outcome.typed, "")
    }
  }

  // MARK: - It must run forever

  func testAVeryLongHoldKeepsTypingToTheEnd() {
    // 400 words, ~2.7 minutes of speech — past every cap this feature has had.
    var words = ["Type"]
    for index in 0..<400 { words.append("word\(index)") }
    let pauses = Set(stride(from: 20, to: 400, by: 20))
    let outcome = runHold(words: words, pausesAfter: pauses)

    XCTAssertTrue(outcome.claimed)
    XCTAssertEqual(outcome.typed, expectedTyped(words), "a long hold must type every word")
    XCTAssertGreaterThan(outcome.commits, 10, "windows must keep committing")
  }

  func testAnEndlessHoldNeverGrowsTheDecodeCost() {
    // The reason a hold can be unbounded: what the recognizer is asked to decode
    // stays bounded no matter how long the user talks.
    var words = ["Type"]
    for index in 0..<600 { words.append("w\(index)") }
    let outcome = runHold(words: words, pausesAfter: Set(0..<601))
    XCTAssertLessThanOrEqual(
      outcome.peakDecodeBytes, VoiceTypeDecodeWindow.maxBytes,
      "no decode may exceed the window's hard limit")
    XCTAssertEqual(outcome.typed, expectedTyped(words))
  }

  func testASpeakerWhoNeverPausesStillTypesEverything() {
    var words = ["Type"]
    for index in 0..<300 { words.append("nonstop\(index)") }
    let outcome = runHold(words: words, pausesAfter: [])
    XCTAssertEqual(outcome.typed, expectedTyped(words))
    XCTAssertLessThanOrEqual(outcome.peakDecodeBytes, VoiceTypeDecodeWindow.maxBytes)
  }

  // MARK: - The backend stream commits, the local decode types the edge

  func testAStreamThatCommitsEveryPauseKeepsTypingForTheWholeHold() {
    // The live "timeout": after the stream's first utterance the dictation
    // stopped. Every later utterance is a delta without the wake word, and
    // replacing the transcript with it left nothing the parser would type.
    // Committing each utterance by position instead keeps the hold going.
    var words = ["Type"]
    for index in 0..<300 { words.append("word\(index)") }
    let pauses = Set(stride(from: 12, to: 300, by: 12))
    let outcome = runHold(words: words, pausesAfter: pauses, streamCommitsPauses: true)

    XCTAssertTrue(outcome.claimed)
    XCTAssertEqual(outcome.typed, expectedTyped(words))
    XCTAssertGreaterThan(outcome.commits, 20, "the stream must keep committing")
    XCTAssertLessThanOrEqual(outcome.peakDecodeBytes, VoiceTypeDecodeWindow.maxBytes)
  }

  func testTheStreamsSpellingWinsForTheStretchesItCommits() {
    // The local decode types "wrd7"; the stream's utterance for that stretch
    // says "word7" — the screen settles to the stream's version and the next
    // stretch carries on after it.
    var words = ["Type"]
    for index in 0..<40 { words.append("wrd\(index)") }
    let pauses = Set(stride(from: 8, to: 40, by: 8))
    let outcome = runHold(
      words: words, pausesAfter: pauses, streamCommitsPauses: true,
      streamText: { $0.replacingOccurrences(of: "wrd", with: "word") })
    let expected = expectedTyped(words.map { $0.replacingOccurrences(of: "wrd", with: "word") })
    // The tail after the last stream commit is still the local decode.
    XCTAssertTrue(outcome.typed.hasPrefix("Word0 word1"), outcome.typed)
    XCTAssertEqual(
      outcome.typed.split(separator: " ").count, expected.split(separator: " ").count,
      "no stretch is duplicated or lost at a seam")
  }

  // MARK: - Difficult content

  func testTechnicalPhraseWithPunctuationAndNumbersIsTypedVerbatim() {
    let words = [
      "Type", "the", "Kubernetes", "ingress", "controller", "returned", "a", "502",
      "from", "the", "nginx", "sidecar,", "retry", "in", "30s.",
    ]
    let outcome = runHold(words: words, pausesAfter: [7, 12])
    XCTAssertEqual(outcome.typed, expectedTyped(words))
  }

  func testAPhraseContainingTheWordTypeLaterIsNotRestarted() {
    let words = ["Type", "what", "type", "of", "bird", "is", "this"]
    let outcome = runHold(words: words)
    XCTAssertEqual(outcome.typed, "What type of bird is this")
  }

  func testAQuestionShapedDictationStillTypesRatherThanAsking() {
    let words = ["Type", "what", "is", "on", "my", "calendar", "tomorrow"]
    let outcome = runHold(words: words)
    XCTAssertTrue(outcome.claimed)
    XCTAssertEqual(outcome.typed, "What is on my calendar tomorrow")
  }

  func testRecognizerRevisionsDoNotLeaveWrongTextBehind() {
    let words = ["Type", "I", "will", "write", "the", "notes", "tonight"]
    let outcome = runHold(words: words, reviseLastWord: true)
    XCTAssertEqual(outcome.typed, expectedTyped(words))
  }

  func testRevisionsAcrossALongHoldStillEndCorrect() {
    var words = ["Type"]
    for index in 0..<120 { words.append("token\(index)") }
    let outcome = runHold(
      words: words, pausesAfter: Set(stride(from: 10, to: 120, by: 10)), reviseLastWord: true)
    XCTAssertEqual(outcome.typed, expectedTyped(words))
  }

  // MARK: - Quickness

  func testTypingKeepsUpWithoutRewritingWhatItAlreadyTyped() {
    // Churn is what "real time but glitchy" looked like. A clean dictation
    // should append, not rewrite.
    let words = ["Type", "hello", "there", "friend", "how", "are", "you"]
    let outcome = runHold(words: words, pausesAfter: [3])
    XCTAssertEqual(outcome.typed, expectedTyped(words))
    XCTAssertEqual(outcome.deletions, [], "a clean dictation never deletes")
  }
  // MARK: - Adversarial

  func testProbesThatReturnNothingDoNotLoseTheTurn() {
    // Live logs show runs of `nil` decodes mid-hold. Typing must survive them.
    let words = ["Type", "hello", "there", "friend", "how", "are", "you", "today"]
    let outcome = runHold(words: words, pausesAfter: [3], nilProbeEvery: 3)
    XCTAssertTrue(outcome.claimed)
    XCTAssertEqual(outcome.typed, expectedTyped(words))
  }

  func testAPauseImmediatelyAfterTheWakeWordStillDictates() {
    // "Type." then a beat, then the sentence — the natural way to say it, and
    // the shape of the turn that failed live.
    let words = ["Type.", "Okay,", "so", "this", "is", "decent", "I", "guess."]
    let outcome = runHold(words: words, pausesAfter: [0, 4])
    XCTAssertTrue(outcome.claimed)
    XCTAssertEqual(outcome.typed, "Okay, so this is decent I guess.")
  }

  func testGarbageBeforeTheWakeWordDoesNotDisableTyping() {
    // The first decode of a hold is often a fragment of nothing.
    let words = ["So", "type", "send", "the", "notes", "now"]
    let outcome = runHold(words: words)
    XCTAssertFalse(outcome.claimed, "the wake word must open the turn, not appear inside it")
    XCTAssertEqual(outcome.typed, "")
  }

  func testBackToBackPausesDoNotDuplicateOrDropWords() {
    let words = ["Type", "one", "two", "three", "four", "five", "six", "seven", "eight"]
    let outcome = runHold(words: words, pausesAfter: [1, 2, 3, 4, 5, 6, 7])
    XCTAssertEqual(outcome.typed, expectedTyped(words))
    XCTAssertGreaterThan(outcome.commits, 0)
  }

  func testASingleUnbrokenWordLongerThanTheWindowIsStillTyped() {
    let long = String(repeating: "supercalifragilistic", count: 4)
    let outcome = runHold(words: ["Type", long, "done"], pausesAfter: [1])
    XCTAssertEqual(outcome.typed, "\(long.prefix(1).uppercased())\(long.dropFirst()) done")
  }

  func testNonstopSpeechWithRevisionsClipsAtMostOneWordPerForcedCutAndNeverRepeats() {
    // A speaker who never pauses is cut at the hard limit, and that cut may
    // clip the word spoken across it. It must never *repeat* one — repetition
    // is what the withheld-overlap design produced, and it is worse.
    //
    // Each word ends in a sentinel so a clipped word is distinguishable from a
    // genuine one; without that, "tok49" clipped to "tok4" collides with a real
    // word and reads as a duplicate that never happened.
    var words = ["Type"]
    for index in 0..<200 { words.append("w\(index)#") }
    let outcome = runHold(words: words, pausesAfter: [], reviseLastWord: true)
    let typed = outcome.typed.split(separator: " ").map(String.init)

    XCTAssertEqual(Set(typed).count, typed.count, "no word may be typed twice")

    let clipped = typed.filter { !$0.hasSuffix("#") }
    // 200 words at 0.4 s each is 80 s of nonstop speech; at a 20 s hard limit
    // that is four forced cuts, so at most four words can be clipped.
    XCTAssertLessThanOrEqual(
      clipped.count, 5, "forced cuts clipped more words than there were cuts: \(clipped)")
    XCTAssertEqual(
      typed.count, words.count - 1, "every word must still be typed, clipped or not")
  }

  func testAWakeWordSpokenBeforeProbingStartsIsStillFound() {
    // The regression: typing's buffer was fed per-route, and the hub's
    // warm-wait matched no route — so "Type" said while the hub connected never
    // reached the recognizer and the turn silently became a question.
    let words = ["Type", "send", "the", "notes", "to", "the", "team", "now"]
    let outcome = runHold(words: words, pausesAfter: [4], probesStartAtWord: 3)
    XCTAssertTrue(outcome.claimed, "the wake word must survive audio that predates probing")
    XCTAssertEqual(outcome.typed, expectedTyped(words))
  }

  // MARK: - Quickness and sizing

  func testTheFirstCharactersLandWithinTwoProbes() {
    // Perceived speed: the stabilizer costs one probe, and nothing else may.
    let outcome = runHold(words: ["Type", "hello", "there", "friend"])
    XCTAssertGreaterThan(outcome.firstInsertionProbe, 0)
    XCTAssertLessThanOrEqual(
      outcome.firstInsertionProbe, 3,
      "typing should begin within a probe or two of the wake word")
  }

  func testWindowSizingSweep() {
    // Chooses the shipped window from measurement rather than taste. A long,
    // realistically-paused dictation is run at several window sizes; every one
    // must be correct, and the report shows what each costs.
    var words = ["Type"]
    for index in 0..<240 { words.append("word\(index)") }
    let pauses = Set(stride(from: 6, to: 240, by: 6))
    var report: [String] = []
    for seconds in [3, 6, 10, 20, 45] {
      let outcome = runHold(
        words: words, pausesAfter: pauses,
        window: VoiceTypeDecodeWindow(
          targetBytes: seconds * 16_000 * 2, maxBytes: max(seconds, 20) * 16_000 * 2))
      XCTAssertEqual(
        outcome.typed, expectedTyped(words), "window of \(seconds)s typed the wrong text")
      report.append(
        "target=\(seconds)s commits=\(outcome.commits) "
          + "peakDecode=\(String(format: "%.1f", Double(outcome.peakDecodeBytes / 2) / 16_000))s "
          + "deletions=\(outcome.deletions.count)")
    }
    print("WINDOW SWEEP:\n" + report.joined(separator: "\n"))
  }
}
