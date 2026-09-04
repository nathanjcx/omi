import XCTest

// Guards for the paste-on-release dictation pipeline. Everything here is pure
// value logic driven through its production API — no live recognizer, no
// pasteboard, and no wall-clock waits (the transcriber's budget is exercised
// through an injected sleeper).

// MARK: - Wake word

final class VoiceTypeCommandParserTests: XCTestCase {

  private func payload(_ transcript: String) -> String? {
    guard case .typing(let payload) = VoiceTypeCommandParser.decide(transcript) else { return nil }
    return payload
  }

  func testDictatesAfterTheWakeWord() {
    XCTAssertEqual(payload("type hello world"), "hello world")
  }

  func testWakeWordIsCaseInsensitive() {
    XCTAssertEqual(payload("Type hello world"), "hello world")
    XCTAssertEqual(payload("TYPE hello world"), "hello world")
  }

  func testPunctuationAfterTheWakeWordIsNotDictated() {
    XCTAssertEqual(payload("Type, hello world"), "hello world")
    XCTAssertEqual(payload("Type: hello world"), "hello world")
    XCTAssertEqual(payload("Type — hello world"), "hello world")
  }

  /// Longest-first, or "type out hello" dictates "out hello".
  func testLongerWakeWordsWinOverShorterOnes() {
    XCTAssertEqual(payload("type out hello world"), "hello world")
    XCTAssertEqual(payload("type this hello world"), "hello world")
  }

  func testWakeWordAsAWordPrefixIsNotACommand() {
    XCTAssertNil(payload("typescript generics, explain them"))
    XCTAssertNil(payload("typing is hard"))
    XCTAssertNil(payload("typed it already"))
  }

  /// A bare wake word carries no dictation, and it is the phrase most likely to
  /// open an ordinary question ("type ... " while the user thinks).
  func testBareWakeWordIsNotACommand() {
    XCTAssertNil(payload("type"))
    XCTAssertNil(payload("Type."))
    XCTAssertNil(payload("type   "))
  }

  func testEmptyTranscriptIsNotACommand() {
    XCTAssertNil(payload(""))
    XCTAssertNil(payload("   \n "))
  }

  func testOrdinaryQuestionIsRejected() {
    XCTAssertNil(payload("what is on my calendar tomorrow"))
  }

  /// The corrector once rewrote the wake word itself from an on-screen keyword
  /// ("Type" → "typ"), after which the turn was never recognised as a dictation
  /// and the realtime model spawned an agent to do the typing.
  func testCorrectionNeverTouchesTheWakeWord() {
    let corrected = VoiceTypeCommandParser.correctingPayload("Type, send it to nate") { payload in
      payload.replacingOccurrences(of: "nate", with: "Nathan")
    }
    XCTAssertEqual(corrected, "Type, send it to Nathan")
  }

  func testCorrectionLeavesANonDictationUntouched() {
    let corrected = VoiceTypeCommandParser.correctingPayload("typescript generics") { _ in "rewritten" }
    XCTAssertEqual(corrected, "typescript generics")
  }
}

// MARK: - Formatting

final class VoiceTypeFormatterTests: XCTestCase {

  func testDropsStandaloneFillers() {
    XCTAssertEqual(VoiceTypeFormatter.format("so um the report is late"), "So the report is late")
    XCTAssertEqual(VoiceTypeFormatter.format("uh hello there"), "Hello there")
  }

  /// "So, um, the thing" has to lose the whole "um," or the tidy-up leaves a
  /// doubled comma behind.
  func testDropsFillersWithTheirAttachedPunctuation() {
    XCTAssertEqual(VoiceTypeFormatter.format("So, um, the thing"), "So, the thing")
  }

  func testKeepsWordsThatMerelyStartLikeAFiller() {
    XCTAssertEqual(VoiceTypeFormatter.format("umbrella season"), "Umbrella season")
    XCTAssertEqual(VoiceTypeFormatter.format("uhtred of bebbanburg"), "Uhtred of bebbanburg")
  }

  /// Words that carry meaning in an ordinary sentence stay, even though a
  /// filler-hunting formatter would be tempted by them.
  func testKeepsMeaningfulInterjections() {
    XCTAssertEqual(VoiceTypeFormatter.format("ah I see"), "Ah I see")
    XCTAssertEqual(VoiceTypeFormatter.format("oh no"), "Oh no")
  }

  func testPullsPunctuationBackOntoItsWord() {
    XCTAssertEqual(VoiceTypeFormatter.format("hello , world ."), "Hello, world.")
    XCTAssertEqual(VoiceTypeFormatter.format("really ? yes !"), "Really? Yes!")
  }

  func testCollapsesRepeatedSpaces() {
    XCTAssertEqual(VoiceTypeFormatter.format("hello    world"), "Hello world")
  }

  func testCapitalizesTheFirstWordAndEachSentence() {
    XCTAssertEqual(
      VoiceTypeFormatter.format("the build is green. ship it."), "The build is green. Ship it.")
  }

  /// Upward only. A recognizer that returned "iPhone" or "API" got it right,
  /// and normalizing case would undo the accuracy this change is for.
  func testNeverLowercasesAWord() {
    XCTAssertEqual(VoiceTypeFormatter.format("the API is down"), "The API is down")
    XCTAssertEqual(VoiceTypeFormatter.format("my iPhone broke"), "My iPhone broke")
    XCTAssertEqual(VoiceTypeFormatter.format("ask McDonald about it"), "Ask McDonald about it")
  }

  /// A period without a following space is an abbreviation or a decimal, not a
  /// sentence boundary.
  func testAbbreviationsAndDecimalsDoNotOpenASentence() {
    XCTAssertEqual(VoiceTypeFormatter.format("use e.g. this one"), "Use e.g. this one")
    XCTAssertEqual(VoiceTypeFormatter.format("ship i.e. release it"), "Ship i.e. release it")
    XCTAssertEqual(VoiceTypeFormatter.format("it took 3.5 hours"), "It took 3.5 hours")
    XCTAssertEqual(VoiceTypeFormatter.format("the U.S. market"), "The U.S. market")
  }

  /// The first *letter* of "3rd" is in the middle of the word; raising it would
  /// produce "3Rd".
  func testAWordOpeningWithADigitIsLeftAlone() {
    XCTAssertEqual(VoiceTypeFormatter.format("3rd time lucky"), "3rd time lucky")
  }

  /// Spoken punctuation commands are deliberately not implemented: "the period
  /// of the wave" is a sentence someone will say, and deleting the word they
  /// did say is a worse accuracy bug than the one it would fix.
  func testSpokenPunctuationWordsSurviveVerbatim() {
    XCTAssertEqual(
      VoiceTypeFormatter.format("the period of the wave"), "The period of the wave")
    XCTAssertEqual(VoiceTypeFormatter.format("add a new line here"), "Add a new line here")
  }

  func testLineStructureSurvives() {
    XCTAssertEqual(VoiceTypeFormatter.format("first line\nsecond line"), "First line\nSecond line")
  }

  func testEmptyTranscriptFormatsToNothing() {
    XCTAssertEqual(VoiceTypeFormatter.format(""), "")
    XCTAssertEqual(VoiceTypeFormatter.format("   "), "")
    XCTAssertEqual(VoiceTypeFormatter.format("um uh"), "")
  }
}

// MARK: - Audio

/// s16le 16 kHz mono, the format every recognizer here is fed.
private func pcm(seconds: Double, amplitude: Int16) -> Data {
  let samples = Int(seconds * 16_000)
  var data = Data(capacity: samples * 2)
  for index in 0..<samples {
    // Alternating sign so the RMS matches the amplitude rather than a DC offset.
    let value = index.isMultiple(of: 2) ? amplitude : -amplitude
    withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
  }
  return data
}

private func silence(_ seconds: Double) -> Data { pcm(seconds: seconds, amplitude: 5) }
private func speech(_ seconds: Double) -> Data { pcm(seconds: seconds, amplitude: 8_000) }

final class VoiceTypeAudioTrimTests: XCTestCase {

  func testLeadingRoomToneIsDroppedAndThePreRollKept() {
    let trimmed = VoiceTypeAudioTrim.trimmingLeadingSilence(silence(3) + speech(1))
    // 1 s of speech plus the 100 ms pre-roll, and nothing like the 3 s lead-in.
    XCTAssertGreaterThan(trimmed.count, speech(1).count)
    XCTAssertLessThan(trimmed.count, speech(1.5).count)
  }

  /// A hold ends when the key comes up, not when the user stops talking, so the
  /// tail is room tone that a recognizer answers with an invented phrase.
  func testTrailingRoomToneIsDroppedAndThePostRollKept() {
    let trimmed = VoiceTypeAudioTrim.trimmingTrailingSilence(speech(1) + silence(3))
    XCTAssertGreaterThan(trimmed.count, speech(1).count)
    XCTAssertLessThan(trimmed.count, speech(1.5).count)
  }

  func testBothEndsAtOnce() {
    let trimmed = VoiceTypeAudioTrim.trimmingSilence(silence(2) + speech(1) + silence(2))
    XCTAssertGreaterThan(trimmed.count, speech(1).count)
    XCTAssertLessThan(trimmed.count, speech(1.5).count)
  }

  func testAnEntirelyQuietBufferTrimsToNothing() {
    XCTAssertTrue(VoiceTypeAudioTrim.trimmingSilence(silence(4)).isEmpty)
    XCTAssertTrue(VoiceTypeAudioTrim.trimmingLeadingSilence(silence(4)).isEmpty)
    XCTAssertTrue(VoiceTypeAudioTrim.trimmingTrailingSilence(silence(4)).isEmpty)
  }

  func testSpeechBytesCountsOnlyTheVoicedWindows() {
    XCTAssertEqual(VoiceTypeAudioTrim.speechBytes(in: silence(2)), 0)
    let mixed = VoiceTypeAudioTrim.speechBytes(in: silence(1) + speech(1))
    XCTAssertGreaterThan(mixed, speech(0.9).count)
    XCTAssertLessThanOrEqual(mixed, speech(1).count)
  }
}

final class VoiceTypeUtteranceTests: XCTestCase {

  func testHoldsEveryChunkOfTheTurn() {
    var utterance = VoiceTypeUtterance()
    utterance.append(speech(0.5))
    utterance.append(speech(0.5))
    XCTAssertEqual(utterance.audio.count, speech(1).count)
    XCTAssertEqual(utterance.seconds, 1, accuracy: 0.01)
    XCTAssertFalse(utterance.didTruncate)
  }

  /// The cap has to bite before the backend batch endpoint would answer 413.
  func testTruncatesAtTheCapAndSaysSo() {
    var utterance = VoiceTypeUtterance(maxBytes: speech(1).count)
    utterance.append(speech(2))
    XCTAssertEqual(utterance.audio.count, speech(1).count)
    XCTAssertTrue(utterance.didTruncate)
  }

  func testChunksArrivingAfterTheCapAreDropped() {
    var utterance = VoiceTypeUtterance(maxBytes: speech(1).count)
    utterance.append(speech(1))
    XCTAssertFalse(utterance.didTruncate)
    utterance.append(speech(1))
    XCTAssertEqual(utterance.audio.count, speech(1).count)
    XCTAssertTrue(utterance.didTruncate)
  }

  func testASilentHoldHasNothingToDecode() {
    var utterance = VoiceTypeUtterance()
    utterance.append(silence(4))
    XCTAssertNil(utterance.decodableAudio())
  }

  /// Below half a second of voice there is no word to recover, only a breath,
  /// and the on-device decoder answers those with an invented phrase.
  func testABreathIsNotWorthDecoding() {
    var utterance = VoiceTypeUtterance()
    utterance.append(silence(1) + speech(0.2) + silence(1))
    XCTAssertNil(utterance.decodableAudio())
  }

  func testRealSpeechIsHandedOverSilenceTrimmed() {
    var utterance = VoiceTypeUtterance()
    utterance.append(silence(2) + speech(2) + silence(2))
    let decodable = utterance.decodableAudio()
    XCTAssertNotNil(decodable)
    XCTAssertLessThan(decodable?.count ?? .max, utterance.audio.count)
    XCTAssertGreaterThan(decodable?.count ?? 0, speech(2).count)
  }

  func testResetClearsTheTurn() {
    var utterance = VoiceTypeUtterance(maxBytes: speech(1).count)
    utterance.append(speech(2))
    utterance.reset()
    XCTAssertTrue(utterance.audio.isEmpty)
    XCTAssertFalse(utterance.didTruncate)
    XCTAssertNil(utterance.decodableAudio())
  }
}

// MARK: - Transcription

final class VoiceTypeTranscriberTests: XCTestCase {

  /// A recognizer that never answers, and is cancelled by the winner of the race.
  private static func neverAnswers() async -> String? {
    await suspendUntilCancelled()
    return nil
  }

  private func transcriber(
    cloud: @escaping VoiceTypeTranscriber.Cloud,
    onDevice: @escaping VoiceTypeTranscriber.OnDevice,
    isReachable: Bool = true,
    budgetExpiresFirst: Bool = false
  ) -> VoiceTypeTranscriber {
    VoiceTypeTranscriber(
      cloud: cloud,
      onDevice: onDevice,
      isReachable: { isReachable },
      // The budget is either instant or never expires, so which side of the
      // race wins is a property of the test rather than of the machine.
      sleep: { _ in
        if !budgetExpiresFirst { await suspendUntilCancelled() }
      })
  }

  func testTheCloudTranscriptWinsWhenItAnswersInTime() async {
    let subject = transcriber(
      cloud: { _, _ in "the cloud heard this" },
      onDevice: { _ in "the local model heard this" })
    let outcome = await subject.transcribe(speech(1), keywords: [])
    XCTAssertEqual(outcome.transcript?.text, "the cloud heard this")
    XCTAssertEqual(outcome.transcript?.source, .cloudBatch)
    XCTAssertNil(outcome.degradation)
  }

  func testTheOnScreenKeywordsReachTheCloudRecognizer() async {
    let seen = KeywordBox()
    let subject = transcriber(
      cloud: { _, keywords in
        await seen.record(keywords)
        return "biased transcript"
      },
      onDevice: { _ in nil })
    _ = await subject.transcribe(speech(1), keywords: ["Nathan", "Parakeet"])
    let recorded = await seen.keywords
    XCTAssertEqual(recorded, ["Nathan", "Parakeet"])
  }

  /// Offline the cloud is not merely slow, it is unreachable, and nothing
  /// should spend the budget discovering that.
  func testOfflineDictationUsesTheOnDeviceModel() async {
    let subject = transcriber(
      cloud: { _, _ in
        XCTFail("the cloud must not be called with no network")
        return nil
      },
      onDevice: { _ in "the local model heard this" },
      isReachable: false)
    let outcome = await subject.transcribe(speech(1), keywords: [])
    XCTAssertEqual(outcome.transcript?.text, "the local model heard this")
    XCTAssertEqual(outcome.transcript?.source, .onDevice)
    XCTAssertEqual(outcome.degradation, .network)
  }

  func testAFailingCloudRequestFallsBackToTheOnDeviceModel() async {
    struct Boom: Error {}
    let subject = transcriber(
      cloud: { _, _ in throw Boom() },
      onDevice: { _ in "the local model heard this" })
    let outcome = await subject.transcribe(speech(1), keywords: [])
    XCTAssertEqual(outcome.transcript?.source, .onDevice)
    XCTAssertEqual(outcome.degradation, .error)
  }

  func testAnEmptyCloudTranscriptFallsBackToTheOnDeviceModel() async {
    let subject = transcriber(
      cloud: { _, _ in "   " },
      onDevice: { _ in "the local model heard this" })
    let outcome = await subject.transcribe(speech(1), keywords: [])
    XCTAssertEqual(outcome.transcript?.source, .onDevice)
    XCTAssertEqual(outcome.degradation, .empty)
  }

  /// The whole reason both recognizers start together: the budget can expire
  /// without the dictation degrading to nothing, because the on-device answer
  /// is already in hand.
  func testABudgetExpiryPastesTheOnDeviceTranscriptRatherThanNothing() async {
    let subject = transcriber(
      cloud: { _, _ in await Self.neverAnswers() },
      onDevice: { _ in "the local model heard this" },
      budgetExpiresFirst: true)
    let outcome = await subject.transcribe(speech(1), keywords: [])
    XCTAssertEqual(outcome.transcript?.text, "the local model heard this")
    XCTAssertEqual(outcome.transcript?.source, .onDevice)
    XCTAssertEqual(outcome.degradation, .timeout)
  }

  func testATurnNeitherRecognizerHeardProducesNoTranscript() async {
    let subject = transcriber(cloud: { _, _ in nil }, onDevice: { _ in nil })
    let outcome = await subject.transcribe(speech(1), keywords: [])
    XCTAssertNil(outcome.transcript)
    XCTAssertEqual(outcome.degradation, .empty)
  }

  func testEmptyAudioIsNotSentToEitherRecognizer() async {
    let subject = transcriber(
      cloud: { _, _ in
        XCTFail("empty audio must not be transcribed")
        return nil
      },
      onDevice: { _ in
        XCTFail("empty audio must not be transcribed")
        return nil
      })
    let outcome = await subject.transcribe(Data(), keywords: [])
    XCTAssertNil(outcome.transcript)
    XCTAssertNil(outcome.degradation)
  }

  func testWhitespaceIsTrimmedOffTheChosenTranscript() async {
    let subject = transcriber(
      cloud: { _, _ in "  padded transcript \n" },
      onDevice: { _ in nil })
    let outcome = await subject.transcribe(speech(1), keywords: [])
    XCTAssertEqual(outcome.transcript?.text, "padded transcript")
  }
}

/// Collects what the injected cloud recognizer was handed, across the
/// concurrency boundary the transcriber's closures cross.
private actor KeywordBox {
  private(set) var keywords: [String] = []

  func record(_ keywords: [String]) {
    self.keywords = keywords
  }
}

/// Suspends until the surrounding task is cancelled, without consulting the clock.
///
/// The transcriber races two children and cancels the loser, so a test needs the
/// loser never to finish on its own. `Task.sleep` would make that a property of
/// the machine's timing rather than of the test, and would spend real seconds
/// whenever a cancellation were missed. Yielding until cancelled is
/// deterministic and costs a handful of cooperative hops.
func suspendUntilCancelled() async {
  while !Task.isCancelled {
    await Task.yield()
  }
}
