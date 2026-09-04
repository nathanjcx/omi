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

final class VoiceTypeWakeWordCorrectionTests: XCTestCase {

  func testTheWakeWordIsNeverHandedToTheCorrector() {
    // Live: a window title containing "typ" made the keyword corrector rewrite
    // "Type" itself, so no probe ever parsed as a dictation and the model
    // spawned an agent to type instead.
    var seen: [String] = []
    let out = VoiceTypeCommandParser.correctingPayload("Type, hello world") { payload in
      seen.append(payload)
      return payload.replacingOccurrences(of: "Type", with: "typ").replacingOccurrences(of: "world", with: "World")
    }
    XCTAssertEqual(seen, ["hello world"])
    XCTAssertEqual(out, "Type, hello World")
    XCTAssertTrue(VoiceTypeCommandParser.stillDictates(out))
  }

  func testAWakeWordCorrectorCannotDisarmTheTurn() {
    let hostile: (String) -> String = { $0.replacingOccurrences(of: "Type", with: "typ") }
    for transcript in ["Type hello", "Type. Hello there.", "type out the report", "Type this: send it"] {
      let out = VoiceTypeCommandParser.correctingPayload(transcript, using: hostile)
      XCTAssertTrue(VoiceTypeCommandParser.stillDictates(out), "\(transcript) → \(out)")
    }
  }

  func testTextThatIsNotYetACommandIsLeftAlone() {
    let out = VoiceTypeCommandParser.correctingPayload("Ty") { _ in
      XCTFail("must not correct")
      return ""
    }
    XCTAssertEqual(out, "Ty")
    XCTAssertEqual(
      VoiceTypeCommandParser.correctingPayload("what is on my calendar") { _ in "changed" },
      "what is on my calendar")
  }
}

final class VoiceTypeStreamFinalAdmissionTests: XCTestCase {

  func testAFinalThatKeepsTheWakeWordMayBecomeThePrefix() {
    XCTAssertTrue(VoiceTypeCommandParser.stillDictates("Type hello world."))
    XCTAssertTrue(VoiceTypeCommandParser.stillDictates("Type hello world. And then more."))
  }

  func testAFirstFinalThatLostTheWakeWordIsRefused() {
    // Freezing "tie the report is due" as the prefix would leave a transcript
    // the parser rejects forever, and nothing could be typed again.
    XCTAssertFalse(VoiceTypeCommandParser.stillDictates("tie the report is due"))
    XCTAssertFalse(VoiceTypeCommandParser.stillDictates(""))
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

  func testACorrectionNearTheMovingEdgeIsStillMade() {
    var planner = VoiceTypeStreamPlanner()
    _ = planner.plan(for: "I will write the notes tonite")
    // Two words back: worth fixing.
    let edit = planner.plan(for: "I will write the notes tonight")
    XCTAssertEqual(edit.backspaces, 2)
    XCTAssertEqual(planner.typed, "I will write the notes tonight")
  }

  func testACorrectionTooFarBackIsNotMade() {
    // Erasing half a sentence to fix a word from ten words ago is violent to
    // watch and fights the user if they have started editing behind the caret.
    var planner = VoiceTypeStreamPlanner()
    _ = planner.plan(for: "the quick brown fox jumps over the lazy dog today")
    let edit = planner.plan(for: "the quick brown cat jumps over the lazy dog today and more")
    XCTAssertEqual(edit.backspaces, 0, "must not rewind past the last few words")
    XCTAssertEqual(edit.insertion, " and more", "the tail keeps flowing")
    XCTAssertEqual(
      planner.typed, "the quick brown fox jumps over the lazy dog today and more",
      "the planner tracks what is really on screen, not what it wished were there")
  }

  func testSettledTextMayCorrectHoweverFarBackItReaches() {
    // A finished utterance from the streaming model, or the closing decode,
    // will not move again; leaving the screen out of step with it would make
    // every later diff run against text that is not there.
    var planner = VoiceTypeStreamPlanner()
    _ = planner.plan(for: "Hello wrold this is a tset of the thing")
    let edit = planner.plan(for: "Hello world, this is a test of the thing.", rewritesFreely: true)
    XCTAssertEqual(edit.backspaces, "rold this is a tset of the thing".count)
    XCTAssertEqual(edit.insertion, "orld, this is a test of the thing.")
    XCTAssertEqual(planner.typed, "Hello world, this is a test of the thing.")
  }

  func testADistantRevisionWithNothingNewEmitsNothing() {
    var planner = VoiceTypeStreamPlanner()
    _ = planner.plan(for: "one two three four five six seven eight")
    XCTAssertTrue(planner.plan(for: "one two THREE four five six seven eight").isEmpty)
  }

  func testNoEditEverDeletesMoreThanTheRewindLimit() {
    // Property: however the transcript is revised, the planner never proposes a
    // deletion longer than the last few words on screen.
    var planner = VoiceTypeStreamPlanner()
    let revisions = [
      "alpha bravo charlie", "alpha bravo charlie delta", "alpha XXXXX charlie delta",
      "alpha bravo charlie delta echo", "completely different text entirely",
      "alpha bravo charlie delta echo foxtrot", "a",
    ]
    for revision in revisions {
      let before = planner.typed
      let limit =
        before.split(separator: " ", omittingEmptySubsequences: false).count
          > VoiceTypeStreamPlanner.maxRewindWords
        ? before.split(separator: " ", omittingEmptySubsequences: false)
          .suffix(VoiceTypeStreamPlanner.maxRewindWords).joined(separator: " ").count
        : before.count
      let edit = planner.plan(for: revision)
      XCTAssertLessThanOrEqual(
        edit.backspaces, limit, "deleted \(edit.backspaces) of \(before.count) for \(revision)")
    }
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
    var caretAfterWord = false
    var focus: String? = "app:1"

    func deleteBackward(_ count: Int) {
      guard count > 0 else { return }
      deletions.append(count)
      typed.removeLast(min(count, typed.count))
    }

    func insert(_ text: String) {
      typed += text
    }

    func caretFollowsWordCharacter() -> Bool { caretAfterWord }
    func focusTarget() -> String? { focus }
  }

  func testTypingPausesWhileFocusIsElsewhereAndCatchesUpWhenItReturns() {
    // Live: a dock click brought Omi's own window forward mid-hold and two
    // stream commits rewrote text inside it instead of the document.
    let (session, sink) = makeSession()
    session.begin()
    session.update(transcript: "Type hello there")
    session.update(transcript: "Type hello there my")
    XCTAssertEqual(sink.typed, "Hello there")
    sink.focus = "omi:2"
    session.update(transcript: "Type hello there my friend")
    session.update(transcript: "Type hello there my friend how", isSettled: true)
    XCTAssertEqual(sink.typed, "Hello there", "nothing is posted into the other app")
    sink.focus = "app:1"
    XCTAssertEqual(
      session.finish(transcript: "Type hello there my friend how are you"),
      .typed("Hello there my friend how are you"))
    XCTAssertEqual(sink.typed, "Hello there my friend how are you", "the document catches up on return")
  }

  func testAnUnreadableFocusNeverPausesTyping() {
    let (session, sink) = makeSession()
    sink.focus = nil
    session.begin()
    session.update(transcript: "Type hello there")
    session.update(transcript: "Type hello there friend")
    XCTAssertEqual(sink.typed, "Hello there")
  }

  private func makeSession(trusted: Bool = true) -> (VoiceTypeSession, RecordingSink) {
    let sink = RecordingSink()
    return (VoiceTypeSession(sink: sink, isAccessibilityTrusted: { trusted }), sink)
  }

  func testADictationThatContinuesALineOpensWithASpace() {
    // Live: a second hold into the same line typed "voiceI think" — the first
    // word landed flush against the previous turn's last word.
    let (session, sink) = makeSession()
    sink.caretAfterWord = true
    session.begin()
    session.update(transcript: "Type I think this")
    session.update(transcript: "Type I think this is")
    XCTAssertEqual(sink.typed, " I think this")
    XCTAssertEqual(
      session.finish(transcript: "Type I think this is good"), .typed("I think this is good"),
      "the separator is on screen but is not part of what was dictated")
    XCTAssertEqual(sink.typed, " I think this is good")
    XCTAssertEqual(sink.deletions, [], "the separator is never retyped")
  }

  func testABareWakeWordLeavesNoStraySeparator() {
    let (session, sink) = makeSession()
    sink.caretAfterWord = true
    session.begin()
    session.update(transcript: "Type")
    session.update(transcript: "Type.")
    _ = session.finish(transcript: "Type.")
    XCTAssertEqual(sink.typed, "", "nothing was dictated, so nothing — not even a space — is typed")
  }

  func testADictationAtALineStartOrAfterASpaceAddsNothing() {
    let (session, sink) = makeSession()
    sink.caretAfterWord = false
    session.begin()
    session.update(transcript: "Type hello there")
    session.update(transcript: "Type hello there friend")
    XCTAssertEqual(sink.typed, "Hello there")
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

  func testTheExactProbeSequenceFromAFailedLiveTurnDictates() {
    // Replayed verbatim from a live turn (pid 85563) that typed nothing and let
    // the model spawn an agent instead. The recognizer heard the wake word on
    // every probe, so if this passes the fault is in the manager's plumbing,
    // not in the parser or the stabilizer.
    let (session, sink) = makeSession()
    session.begin()
    for probe in [
      "Type.",
      "Type and",
      "Type. I don't know.",
      "Type. I don't know.",
      "Type. I don't know why.",
      "Type, I don't know why I did that.",
      "Type, I don't know why I did that.",
    ] {
      session.update(transcript: probe)
    }
    XCTAssertTrue(session.claimsTurn, "the turn should have been claimed for typing")
    XCTAssertFalse(sink.typed.isEmpty, "something should have been typed")
  }

  func testAWakeWordFollowedByAFullStopStillDictates() {
    // "Type." is what the recognizer returns when the user pauses after the
    // wake word, which is the natural way to say it.
    let (session, _) = makeSession()
    session.begin()
    session.update(transcript: "Type. Okay, so this is decent I guess.")
    session.update(transcript: "Type. Okay, so this is decent I guess.")
    XCTAssertTrue(session.claimsTurn)
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
    // A late transcript revision (recognizer or lexical correction) lands only
    // on the closing decode, after the probes have already typed the old text.
    XCTAssertEqual(session.finish(transcript: "Type send it to Nathan"), .typed("Send it to Nathan"))
    XCTAssertEqual(sink.typed, "Send it to Nathan")
  }

  func testASettledStreamUtteranceRewritesTheLocalGuessAndTypingContinuesAfterIt() {
    // The manager feeds a stream commit as a settled transcript: committed
    // prefix only, moving edge empty. It may rewrite the whole sentence the
    // probes guessed, and the next probe's tail appends after it cleanly.
    let (session, sink) = makeSession()
    session.begin()
    session.update(transcript: "Type hello wrold this is a tset")
    session.update(transcript: "Type hello wrold this is a tset")
    XCTAssertEqual(sink.typed, "Hello wrold this is a tset")
    XCTAssertTrue(session.update(transcript: "Type hello world, this is a test.", isSettled: true))
    XCTAssertEqual(sink.typed, "Hello world, this is a test.")
    session.update(transcript: "Type hello world, this is a test. and it")
    XCTAssertTrue(session.update(transcript: "Type hello world, this is a test. and it goes on"))
    XCTAssertEqual(sink.typed, "Hello world, this is a test. and it")
    XCTAssertEqual(
      session.finish(transcript: "Type hello world, this is a test. and it goes on"),
      .typed("Hello world, this is a test. and it goes on"))
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

  func testOnlyTheOpenFlushWindowIsOwned() {
    // The backend stream is finalized asynchronously, so the caller waits for
    // its last words. It must not close a turn that has since been replaced.
    let (session, _) = makeSession()
    session.begin()
    session.update(transcript: "Type hello")
    let token = session.beginFlush()
    XCTAssertTrue(session.isFlushing(token: token))
    session.begin()
    XCTAssertFalse(
      session.isFlushing(token: token), "a new turn invalidates the previous flush window")
  }

  func testAClosedFlushIsNoLongerOwned() {
    let (session, _) = makeSession()
    session.begin()
    session.update(transcript: "Type hello")
    let token = session.beginFlush()
    _ = session.endFlush(token: token, finalTranscript: "Type hello there")
    XCTAssertFalse(session.isFlushing(token: token))
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

final class VoiceTypeDecodeWindowTests: XCTestCase {

  private func audio(seconds: Double) -> Data {
    Data(count: Int(seconds * 16_000) * 2)
  }

  func testAShortWindowIsNotCommittedYet() {
    var w = VoiceTypeDecodeWindow()
    w.append(audio(seconds: 3))
    XCTAssertFalse(w.commitIfReady(tail: "hello there", endsQuiet: true, tailIsStable: true))
    XCTAssertFalse(w.hasCommitted)
    XCTAssertEqual(w.transcript(tail: "hello there"), "hello there")
  }

  func testCommitsAtAPauseOnceLongEnoughAndDropsThatAudio() {
    // Once text is typed it stops being reconsidered, and its audio stops
    // being decoded — that is what keeps every probe cheap on a long hold.
    var w = VoiceTypeDecodeWindow()
    w.append(audio(seconds: 7))
    XCTAssertTrue(w.commitIfReady(tail: "the first part", endsQuiet: true, tailIsStable: true))
    XCTAssertEqual(w.pendingAudio.count, 0, "committed audio is dropped")
    XCTAssertEqual(
      w.transcript(tail: "and the rest"), "the first part and the rest",
      "the planner still receives the whole utterance")
  }

  func testMidWordIsNotCutWhileTheSpeakerIsStillTalking() {
    // Committing mid-word hands the next window a fragment, which it spells
    // wrong. Past the target the window waits for a pause.
    var w = VoiceTypeDecodeWindow()
    w.append(audio(seconds: 7))
    XCTAssertFalse(w.commitIfReady(tail: "still going", endsQuiet: false, tailIsStable: true))
    XCTAssertFalse(w.hasCommitted)
  }

  func testASpeakerWhoNeverPausesIsForcedAtTheHardLimit() {
    var w = VoiceTypeDecodeWindow()
    w.append(audio(seconds: 21))
    XCTAssertTrue(w.commitIfReady(tail: "no breath at all", endsQuiet: false, tailIsStable: false))
    XCTAssertEqual(w.pendingAudio.count, 0)
  }

  func testCommittingRepeatsSoAHoldHasNoLengthLimit() {
    var w = VoiceTypeDecodeWindow()
    for word in ["one", "two", "three"] {
      w.append(audio(seconds: 7))
      XCTAssertTrue(w.commitIfReady(tail: word, endsQuiet: true, tailIsStable: true))
    }
    XCTAssertEqual(w.transcript(tail: "four"), "one two three four")
    XCTAssertEqual(w.pendingAudio.count, 0)
  }

  func testASilentWindowIsNeverCommitted() {
    // Committing silence would strand the rest of the turn behind a prefix
    // that can never be revised.
    var w = VoiceTypeDecodeWindow()
    w.append(audio(seconds: 25))
    XCTAssertFalse(w.commitIfReady(tail: "   ", endsQuiet: true, tailIsStable: true))
    XCTAssertFalse(w.hasCommitted)
  }

  private func bytes(seconds: Double) -> Int { Int(seconds * 16_000) * 2 }

  /// Speech-level PCM (well above `VoiceTypeAudioTrim.speechRMSThreshold`).
  private func loud(seconds: Double) -> Data {
    var data = Data(capacity: bytes(seconds: seconds))
    for index in 0..<Int(seconds * 16_000) {
      let value = Int16(index % 2 == 0 ? 3000 : -3000)
      withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }
    return data
  }

  func testAStreamSeamInsideAWordSlidesForwardToTheNextPause() {
    // The stream's utterance `end` landed 100 ms before the word stopped
    // sounding. Cutting there gave the next window the word's last syllable,
    // typed as a word of its own ("thinking ng"). The seam moves to the pause.
    var w = VoiceTypeDecodeWindow()
    w.append(loud(seconds: 2.0))
    w.append(audio(seconds: 0.5))  // the pause
    w.append(loud(seconds: 1.0))  // the next word
    XCTAssertEqual(
      w.adoptStreamFinal(text: "Type this is thinking.", startByte: 0, endByte: bytes(seconds: 1.9)),
      .adopted)
    XCTAssertEqual(w.consumedBytes, bytes(seconds: 2.0), "the seam is at the start of the pause, not inside the word")
    XCTAssertEqual(w.pendingAudio.count, bytes(seconds: 1.5))
  }

  func testAStreamFinalAfterUncommittedSpeechIsRefused() {
    // Live: a forced local cut at 20 s, the stream's straddling utterance
    // refused, then its next final (from 29.9 s) adopted — and the two
    // sentences spoken between 20 s and 29.9 s were dropped with the audio,
    // having only ever been the moving edge.
    var w = VoiceTypeDecodeWindow()
    w.append(loud(seconds: 20))
    XCTAssertTrue(w.commitIfReady(tail: "type first twenty seconds", endsQuiet: false, tailIsStable: false))
    w.append(loud(seconds: 10))  // speech the local decode is still typing
    w.append(audio(seconds: 0.5))
    w.append(loud(seconds: 4))  // the utterance the stream finished
    w.append(audio(seconds: 1))
    XCTAssertEqual(
      w.adoptStreamFinal(
        text: "Let me know if you want a ticket.",
        startByte: bytes(seconds: 30.5), endByte: bytes(seconds: 34.5)),
      .uncommittedSpeechBefore)
    XCTAssertEqual(w.consumedBytes, bytes(seconds: 20), "nothing is dropped")
    XCTAssertEqual(w.committedText, "type first twenty seconds")
  }

  func testASubHalfSecondGapIsNotDecodedAndNotAnObstacle() {
    // A breath or a syllable's tail between a local commit and the stream's
    // next utterance decoded as "Thank you." — twice in one hold.
    var w = VoiceTypeDecodeWindow()
    w.append(loud(seconds: 6))
    XCTAssertTrue(w.commitIfReady(tail: "type six seconds", endsQuiet: true, tailIsStable: true))
    w.append(loud(seconds: 0.3))
    w.append(audio(seconds: 0.4))
    w.append(loud(seconds: 3))
    XCTAssertNil(w.uncommittedSpeech(before: bytes(seconds: 6.7)))
    XCTAssertEqual(
      w.adoptStreamFinal(text: "and then more.", startByte: bytes(seconds: 6.7), endByte: bytes(seconds: 9.7)),
      .adopted)
  }

  func testAStreamFinalAfterASilentGapIsAdoptedAndTheGapDropped() {
    var w = VoiceTypeDecodeWindow()
    w.append(loud(seconds: 6))
    XCTAssertTrue(w.commitIfReady(tail: "type six seconds", endsQuiet: true, tailIsStable: true))
    w.append(audio(seconds: 2.5))  // the speaker thinks
    w.append(loud(seconds: 3))
    w.append(audio(seconds: 1))
    XCTAssertEqual(
      w.adoptStreamFinal(text: "and then more.", startByte: bytes(seconds: 8.5), endByte: bytes(seconds: 11.5)),
      .adopted)
    XCTAssertEqual(w.committedText, "type six seconds and then more.")
    XCTAssertEqual(w.consumedBytes, bytes(seconds: 11.5))
  }

  func testAStreamSeamAlreadyOnAPauseStaysPut() {
    var w = VoiceTypeDecodeWindow()
    w.append(loud(seconds: 2.0))
    w.append(audio(seconds: 1.0))
    XCTAssertEqual(
      w.adoptStreamFinal(text: "Type words.", startByte: 0, endByte: bytes(seconds: 2.2)),
      .adopted)
    XCTAssertEqual(w.consumedBytes, bytes(seconds: 2.2))
  }

  func testAStreamSeamWithNoPauseInReachCutsWhereTheStreamSaid() {
    // A speaker who does not pause after the utterance: better one clipped
    // syllable than dropping a second of speech looking for silence.
    var w = VoiceTypeDecodeWindow()
    w.append(loud(seconds: 4.0))
    XCTAssertEqual(
      w.adoptStreamFinal(text: "Type nonstop.", startByte: 0, endByte: bytes(seconds: 1.5)),
      .adopted)
    XCTAssertEqual(w.consumedBytes, bytes(seconds: 1.5))
  }

  func testAStreamFinalCommitsItsStretchAndDropsExactlyThatAudio() {
    var w = VoiceTypeDecodeWindow()
    w.append(audio(seconds: 5))
    XCTAssertEqual(
      w.adoptStreamFinal(text: " Type hello world. ", startByte: 0, endByte: bytes(seconds: 3)),
      .adopted)
    XCTAssertEqual(w.committedText, "Type hello world.")
    XCTAssertEqual(w.consumedBytes, bytes(seconds: 3))
    XCTAssertEqual(w.pendingAudio.count, bytes(seconds: 2), "the audio after the utterance stays pending")
    XCTAssertEqual(w.transcript(tail: "this is"), "Type hello world. this is")
  }

  func testConsecutiveStreamFinalsAccumulateInsteadOfReplacing() {
    // The live bug: the stream forwards one finished utterance per message —
    // a delta, never the whole transcript. Replacing the transcript with each
    // message left "This is a test." without its wake word, and typing froze
    // after the first pause. Each final must extend the committed prefix.
    var w = VoiceTypeDecodeWindow()
    w.append(audio(seconds: 10))
    w.adoptStreamFinal(text: "Type hello world.", startByte: 0, endByte: bytes(seconds: 3))
    XCTAssertEqual(
      w.adoptStreamFinal(
        text: "This is a test.", startByte: bytes(seconds: 3.5), endByte: bytes(seconds: 6)),
      .adopted)
    XCTAssertEqual(w.committedText, "Type hello world. This is a test.")
    XCTAssertEqual(w.consumedBytes, bytes(seconds: 6))
    XCTAssertEqual(w.pendingAudio.count, bytes(seconds: 4))
  }

  func testAStreamFinalInsideALocallyCommittedRegionIsDroppedNotTypedTwice() {
    // The local decode froze this pause first (the stream was slow). The
    // stream's version of the same words arrives later and must not be
    // appended as a second copy of the sentence.
    var w = VoiceTypeDecodeWindow()
    w.append(audio(seconds: 8))
    XCTAssertTrue(w.commitIfReady(tail: "type local words here", endsQuiet: true, tailIsStable: true))
    let consumed = w.consumedBytes
    XCTAssertEqual(
      w.adoptStreamFinal(text: "Type local words here.", startByte: 0, endByte: bytes(seconds: 7)),
      .alreadyCommitted)
    XCTAssertEqual(w.committedText, "type local words here")
    XCTAssertEqual(w.consumedBytes, consumed)
  }

  func testAStreamFinalThatStraddlesTheConsumedEdgeIsDropped() {
    var w = VoiceTypeDecodeWindow()
    w.append(audio(seconds: 8))
    XCTAssertTrue(w.commitIfReady(tail: "type first part", endsQuiet: true, tailIsStable: true))
    w.append(audio(seconds: 4))
    XCTAssertEqual(
      w.adoptStreamFinal(
        text: "first part and more", startByte: bytes(seconds: 6), endByte: bytes(seconds: 10)),
      .alreadyCommitted, "an utterance that began inside frozen audio belongs to the local commit")
    XCTAssertEqual(w.pendingAudio.count, bytes(seconds: 4), "no pending audio is dropped for a refused final")
  }

  func testStreamPositionsAreTurnRelativeSoALateSocketStillAligns() {
    // The stream opened after a local commit: its time zero is the consumed
    // edge, and the caller offsets its positions by that origin. What matters
    // here is that the window trims by absolute turn position, never by
    // stream-relative seconds.
    var w = VoiceTypeDecodeWindow()
    w.append(audio(seconds: 8))
    XCTAssertTrue(w.commitIfReady(tail: "type opening words", endsQuiet: true, tailIsStable: true))
    let origin = w.consumedBytes
    w.append(audio(seconds: 6))
    XCTAssertEqual(
      w.adoptStreamFinal(
        text: "and the rest.", startByte: origin + bytes(seconds: 0.2), endByte: origin + bytes(seconds: 4)),
      .adopted)
    XCTAssertEqual(w.committedText, "type opening words and the rest.")
    XCTAssertEqual(w.pendingAudio.count, bytes(seconds: 2))
  }

  func testEmptyOrAlreadyPastFinalsAreIgnored() {
    var w = VoiceTypeDecodeWindow()
    w.append(audio(seconds: 4))
    XCTAssertEqual(w.adoptStreamFinal(text: "  ", startByte: 0, endByte: bytes(seconds: 2)), .ignored)
    XCTAssertEqual(w.adoptStreamFinal(text: "x", startByte: 0, endByte: 0), .ignored)
    XCTAssertFalse(w.hasCommitted)
    XCTAssertEqual(w.pendingAudio.count, bytes(seconds: 4))
  }

  func testAWindowOpeningMidSentenceIsNotCapitalized() {
    // Each window is a fresh utterance to the recognizer, which capitalizes
    // its first word. Live: "However, A few users still report".
    var w = VoiceTypeDecodeWindow()
    w.append(audio(seconds: 7))
    XCTAssertTrue(w.commitIfReady(tail: "Type on most devices. However,", endsQuiet: true, tailIsStable: true))
    XCTAssertEqual(
      w.transcript(tail: "A few users still report"),
      "Type on most devices. However, a few users still report")
  }

  func testAWindowOpeningANewSentenceKeepsItsCapital() {
    var w = VoiceTypeDecodeWindow()
    w.append(audio(seconds: 7))
    XCTAssertTrue(w.commitIfReady(tail: "Type it fixed the issue.", endsQuiet: true, tailIsStable: true))
    XCTAssertEqual(w.transcript(tail: "However, a few"), "Type it fixed the issue. However, a few")
    XCTAssertEqual(
      VoiceTypeDecodeWindow.continuingSentence(after: "send it to", tail: "I think"), "I think",
      "the pronoun keeps its capital")
    XCTAssertEqual(
      VoiceTypeDecodeWindow.continuingSentence(after: "send it to", tail: "I'll go"), "I'll go")
    XCTAssertEqual(
      VoiceTypeDecodeWindow.continuingSentence(after: "the", tail: "API is down"), "API is down",
      "an acronym keeps its capitals")
  }

  func testUncommittedSpeechBeforeAFinalIsHandedBackForALocalDecode() {
    var w = VoiceTypeDecodeWindow()
    w.append(loud(seconds: 20))
    XCTAssertTrue(w.commitIfReady(tail: "type first twenty seconds", endsQuiet: false, tailIsStable: false))
    w.append(loud(seconds: 10))
    w.append(audio(seconds: 0.5))
    w.append(loud(seconds: 4))
    let gap = w.uncommittedSpeech(before: bytes(seconds: 30.5))
    XCTAssertEqual(gap?.count, bytes(seconds: 10.5), "the ten seconds of speech plus the pause before the utterance")
    XCTAssertNil(w.uncommittedSpeech(before: bytes(seconds: 20)), "no gap, nothing to decode")
    // Committed together, from the consumed edge, the final no longer follows a gap.
    XCTAssertEqual(
      w.adoptStreamFinal(
        text: "and the ten seconds Let me know.", startByte: bytes(seconds: 20), endByte: bytes(seconds: 34.5)),
      .adopted)
    XCTAssertEqual(w.committedText, "type first twenty seconds and the ten seconds Let me know.")
  }

  func testPendingAudioStaysZeroIndexedAfterAStreamCommit() {
    // Crashed live: `removeFirst` left `pendingAudio` starting at the dropped
    // offset, and the trimmer's absolute `subdata(in:)` trapped on the first
    // probe after a stream commit.
    var w = VoiceTypeDecodeWindow()
    w.append(loud(seconds: 3))
    w.append(audio(seconds: 0.5))
    w.append(loud(seconds: 2))
    XCTAssertEqual(w.adoptStreamFinal(text: "Type first.", startByte: 0, endByte: bytes(seconds: 3)), .adopted)
    XCTAssertEqual(w.pendingAudio.startIndex, 0)
    XCTAssertEqual(VoiceTypeAudioTrim.trimmingLeadingSilence(w.pendingAudio).count, bytes(seconds: 2) + 3_200)
    XCTAssertNotNil(w.uncommittedSpeech(before: w.appendedBytes))
    XCTAssertFalse(VoiceTypeAudioTrim.endsQuiet(w.pendingAudio))
  }

  func testTheTrimmerHandlesASlicedBuffer() {
    var data = Data(count: bytes(seconds: 1))
    data.append(loud(seconds: 1))
    let slice = data.dropFirst(bytes(seconds: 0.5))
    XCTAssertEqual(VoiceTypeAudioTrim.trimmingLeadingSilence(slice).count, bytes(seconds: 1) + 3_200)
  }

  func testAppendedBytesTrackTheTurnTimeline() {
    var w = VoiceTypeDecodeWindow()
    w.append(audio(seconds: 7))
    XCTAssertTrue(w.commitIfReady(tail: "type seven seconds", endsQuiet: true, tailIsStable: true))
    w.append(audio(seconds: 2))
    XCTAssertEqual(w.consumedBytes, bytes(seconds: 7))
    XCTAssertEqual(w.appendedBytes, bytes(seconds: 9))
    w.reset()
    XCTAssertEqual(w.consumedBytes, 0)
    XCTAssertEqual(w.appendedBytes, 0)
  }

  func testResetForgetsTheTurn() {
    var w = VoiceTypeDecodeWindow()
    w.append(audio(seconds: 7))
    _ = w.commitIfReady(tail: "previous turn", endsQuiet: true, tailIsStable: true)
    w.reset()
    XCTAssertFalse(w.hasCommitted)
    XCTAssertEqual(w.pendingAudio.count, 0)
    XCTAssertEqual(w.transcript(tail: "new turn"), "new turn")
  }
}

final class VoiceTypeAudioPauseTests: XCTestCase {

  func testSilenceAtTheEndReadsAsAPause() {
    let speech = (0..<16_000).map { Int16(truncatingIfNeeded: ($0 % 2 == 0 ? 6_000 : -6_000)) }
    var samples = speech
    samples.append(contentsOf: [Int16](repeating: 0, count: 16_000))
    var copy = samples.map { $0.littleEndian }
    let data = copy.withUnsafeMutableBufferPointer { Data(buffer: $0) }
    XCTAssertTrue(VoiceTypeAudioTrim.endsQuiet(data))
  }

  func testSpeechAtTheEndIsNotAPause() {
    let speech = (0..<32_000).map { Int16(truncatingIfNeeded: ($0 % 2 == 0 ? 6_000 : -6_000)) }
    var copy = speech.map { $0.littleEndian }
    let data = copy.withUnsafeMutableBufferPointer { Data(buffer: $0) }
    XCTAssertFalse(VoiceTypeAudioTrim.endsQuiet(data))
  }
}

final class DictationLexicalCorrectionTests: XCTestCase {

  func testAnOnScreenNameCorrectsAGreetingTarget() {
    // What the corrector actually covers: a name in a greeting construct.
    // Dictation decoded straight from the recognizer and never got even this.
    XCTAssertEqual(
      PTTTranscriptContextualCorrector.correct("send hi to nate", keywords: ["Nathan"]),
      "send hi to Nathan")
  }

  func testCorrectionIsIdempotentSoCorrectingEveryProbeCannotFlicker() {
    // The stabilizer releases text once two consecutive decodes agree. If
    // correction were unstable, correcting each probe would break that
    // agreement and reintroduce the flicker the stabilizer exists to remove.
    let once = PTTTranscriptContextualCorrector.correct("send hi to nate", keywords: ["Nathan"])
    let twice = PTTTranscriptContextualCorrector.correct(once, keywords: ["Nathan"])
    XCTAssertEqual(once, twice)
  }

  func testTheCorrectorLeavesAWakeWordIntact() {
    // Dictation now runs every probe through the corrector. If it altered the
    // opening word at all, the parser would stop recognising the command.
    for probe in [
      "Type.",
      "Type. I don't know.",
      "Type, I don't know why I did that.",
      "Type. Okay, so this is decent I guess.",
    ] {
      XCTAssertEqual(
        PTTTranscriptContextualCorrector.correct(probe, keywords: []), probe,
        "the corrector must not touch \(probe)")
    }
  }

  func testNoKeywordsLeavesDictationAlone() {
    // With Screen Recording denied there are no keywords, and dictation must
    // still be typed exactly as heard.
    XCTAssertEqual(
      PTTTranscriptContextualCorrector.correct("send hi to nate", keywords: []),
      "send hi to nate")
  }

  func testAnOnScreenNameOutsideAGreetingIsNotCorrected() {
    // The limit of the existing corrector, pinned so it is not mistaken for
    // general proper-noun correction: plain dictation is left as heard even
    // with the right spelling on screen. Closing this gap needs recognizer-level
    // vocabulary biasing, not another regex.
    XCTAssertEqual(
      PTTTranscriptContextualCorrector.correct("send it to nate", keywords: ["Nathan"]),
      "send it to nate")
  }
}

final class PTTRoutePolicyTests: XCTestCase {

  func testNoNetworkDictatesOnDeviceInsteadOfWaitingForAHubItCannotReach() {
    // The bug this guards: offline, every remote route (hub, omni, batch STT) is
    // unreachable, so a turn spent its whole warm deadline before failing and
    // typed nothing — while the model that could have typed it was already
    // loaded on-device.
    XCTAssertEqual(
      PTTRoutePolicy.decide(isOnline: false, admitsImmediately: false), .onDeviceDictation)
  }

  func testNoNetworkWinsOverAHubThatClaimsToBeAdmitted() {
    // An admitted hub is a socket that was admitted, not one that can still
    // carry the turn. With no path, believing it costs the user the turn.
    XCTAssertEqual(
      PTTRoutePolicy.decide(isOnline: false, admitsImmediately: true), .onDeviceDictation)
  }

  func testOnlineKeepsTheExistingHubRouting() {
    XCTAssertEqual(
      PTTRoutePolicy.decide(isOnline: true, admitsImmediately: true), .hubImmediate)
    XCTAssertEqual(
      PTTRoutePolicy.decide(isOnline: true, admitsImmediately: false), .hubWarmWait)
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
