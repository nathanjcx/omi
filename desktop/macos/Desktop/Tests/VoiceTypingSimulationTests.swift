import XCTest

// End-to-end simulation of the paste-on-release dictation pipeline: a scripted
// hold goes in as PCM, and what would land in the focused app comes out.
//
// This drives the real production types in the real order — the same order
// `PushToTalkManager` drives them at key-up — with the two recognizers and the
// on-screen keyword corrector injected. Delivery itself (Accessibility, the
// pasteboard, ⌘V) is the one link not modelled here; it needs AppKit and lives
// in `VoiceTypingDeliveryTests`.
//
// The simulation exists because the accuracy claim behind this design is a
// property of the *pipeline*, not of any one of its parts: the recognizer is
// handed the whole utterance exactly once, and no earlier answer can reach the
// screen. A unit test of the formatter cannot say whether that is still true.

/// s16le 16 kHz mono.
private func pcm(seconds: Double, amplitude: Int16) -> Data {
  let samples = Int(seconds * 16_000)
  var data = Data(capacity: samples * 2)
  for index in 0..<samples {
    let value = index.isMultiple(of: 2) ? amplitude : -amplitude
    withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
  }
  return data
}

private func roomTone(_ seconds: Double) -> Data { pcm(seconds: seconds, amplitude: 5) }
private func voice(_ seconds: Double) -> Data { pcm(seconds: seconds, amplitude: 8_000) }

/// One simulated hold.
private struct DictationRun {
  /// What the cloud batch recognizer returns for the whole utterance, or nil
  /// when it has nothing / cannot be reached.
  var cloudHeard: String?
  var cloudThrows = false
  var cloudExceedsBudget = false
  var isReachable = true
  /// What the on-device model returns for the whole utterance.
  var localHeard: String?
  /// Keywords visible on screen, and the correction they imply.
  var keywords: [String] = []
  var corrections: [String: String] = [:]
  /// Chunks as the microphone would deliver them.
  var chunks: [Data] = [roomTone(0.5), voice(2), roomTone(0.5)]
  var maxBytes: Int = VoiceTypeUtterance.defaultMaxBytes

  struct Result {
    /// The text that would be pasted, or nil when the turn was not a dictation
    /// or held nothing worth decoding.
    let pasted: String?
    let source: VoiceTypeTranscript.Source?
    let degradation: VoiceTypeTranscriber.Degradation?
    let heldSeconds: Double
    let truncated: Bool
    /// How many times a recognizer was handed audio. The whole point of the
    /// design is that this is one.
    let decodeCount: Int
  }

  func run() async -> Result {
    var utterance = VoiceTypeUtterance(maxBytes: maxBytes)
    for chunk in chunks { utterance.append(chunk) }

    let counter = DecodeCounter()
    guard let audio = utterance.decodableAudio() else {
      return Result(
        pasted: nil, source: nil, degradation: nil, heldSeconds: utterance.seconds,
        truncated: utterance.didTruncate, decodeCount: 0)
    }

    let cloudHeard = cloudHeard
    let cloudThrows = cloudThrows
    let localHeard = localHeard
    let cloudExceedsBudget = cloudExceedsBudget
    let isReachable = isReachable
    let transcriber = VoiceTypeTranscriber(
      cloud: { _, _ in
        await counter.record()
        if cloudThrows { throw SimulatedFailure() }
        if cloudExceedsBudget { await suspendUntilCancelled() }
        return cloudHeard
      },
      onDevice: { _ in
        await counter.record()
        return localHeard
      },
      isReachable: { isReachable },
      sleep: { _ in
        if !cloudExceedsBudget { await suspendUntilCancelled() }
      })

    let outcome = await transcriber.transcribe(audio, keywords: keywords)
    let decodeCount = await counter.count
    guard let transcript = outcome.transcript else {
      return Result(
        pasted: nil, source: nil, degradation: outcome.degradation,
        heldSeconds: utterance.seconds, truncated: utterance.didTruncate,
        decodeCount: decodeCount)
    }

    // The corrector runs on the dictated text only. A screen keyword must never
    // reach the wake word: live, a window title containing "typ" rewrote "Type"
    // itself and the turn stopped parsing as a dictation at all.
    let corrections = corrections
    let corrected = VoiceTypeCommandParser.correctingPayload(transcript.text) { payload in
      corrections.reduce(payload) { text, pair in
        text.replacingOccurrences(of: pair.key, with: pair.value)
      }
    }
    guard case .typing(let payload) = VoiceTypeCommandParser.decide(corrected) else {
      return Result(
        pasted: nil, source: transcript.source, degradation: outcome.degradation,
        heldSeconds: utterance.seconds, truncated: utterance.didTruncate,
        decodeCount: decodeCount)
    }
    let formatted = VoiceTypeFormatter.format(payload)
    return Result(
      pasted: formatted.isEmpty ? nil : formatted, source: transcript.source,
      degradation: outcome.degradation, heldSeconds: utterance.seconds,
      truncated: utterance.didTruncate, decodeCount: decodeCount)
  }
}

private struct SimulatedFailure: Error {}

private actor DecodeCounter {
  private(set) var count = 0
  func record() { count += 1 }
}

final class VoiceTypingSimulationTests: XCTestCase {

  func testAWholeHoldIsPastedFromTheCloudTranscript() async {
    var run = DictationRun()
    run.cloudHeard = "type the deploy finished, we are good to ship"
    run.localHeard = "type the deploy finish we are good to shape"
    let result = await run.run()
    XCTAssertEqual(result.pasted, "The deploy finished, we are good to ship")
    XCTAssertEqual(result.source, .cloudBatch)
    XCTAssertNil(result.degradation)
  }

  /// The property the whole design rests on: the utterance is decoded once, not
  /// once per window. Both recognizers are handed it exactly one time each.
  func testTheHoldIsDecodedOncePerRecognizerAndNoMore() async {
    var run = DictationRun()
    run.cloudHeard = "type hello"
    run.localHeard = "type hello"
    run.chunks = Array(repeating: voice(1), count: 30)
    let result = await run.run()
    XCTAssertEqual(result.decodeCount, 2)
    XCTAssertEqual(result.heldSeconds, 30, accuracy: 0.01)
  }

  func testFillersAndPunctuationSpacingAreTidiedBeforeThePaste() async {
    var run = DictationRun()
    run.cloudHeard = "type um so the build is green . ship it"
    let result = await run.run()
    XCTAssertEqual(result.pasted, "So the build is green. Ship it")
  }

  /// Offline the on-device model is the only recognizer, and dictation still
  /// works end to end — the one capability that has to survive with no network.
  func testOfflineHoldStillPastesFromTheOnDeviceModel() async {
    var run = DictationRun()
    run.isReachable = false
    run.cloudHeard = "type this must not be used"
    run.localHeard = "type the meeting moved to thursday"
    let result = await run.run()
    XCTAssertEqual(result.pasted, "The meeting moved to thursday")
    XCTAssertEqual(result.source, .onDevice)
    XCTAssertEqual(result.degradation, .network)
  }

  func testACloudFailureFallsBackWithoutLosingTheDictation() async {
    var run = DictationRun()
    run.cloudThrows = true
    run.localHeard = "type ship it today"
    let result = await run.run()
    XCTAssertEqual(result.pasted, "Ship it today")
    XCTAssertEqual(result.source, .onDevice)
    XCTAssertEqual(result.degradation, .error)
  }

  /// A slow network must cost latency, never the dictation. The on-device
  /// answer was computed in parallel and is already in hand.
  func testASlowCloudPastesTheOnDeviceTranscriptInstead() async {
    var run = DictationRun()
    run.cloudExceedsBudget = true
    run.localHeard = "type ship it today"
    let result = await run.run()
    XCTAssertEqual(result.pasted, "Ship it today")
    XCTAssertEqual(result.source, .onDevice)
    XCTAssertEqual(result.degradation, .timeout)
  }

  func testOnScreenKeywordsCorrectTheDictatedTextButNotTheWakeWord() async {
    var run = DictationRun()
    run.cloudHeard = "type send the draft to nate"
    run.keywords = ["Nathan"]
    run.corrections = ["nate": "Nathan"]
    let result = await run.run()
    XCTAssertEqual(result.pasted, "Send the draft to Nathan")
  }

  /// The failure this replaced: a screen keyword rewrote the wake word, the
  /// turn stopped parsing as a dictation, and the realtime model — hearing
  /// "type …" — spawned an agent to do the typing instead.
  func testAScreenKeywordCannotEatTheWakeWord() async {
    var run = DictationRun()
    run.cloudHeard = "type hello world"
    run.keywords = ["typ"]
    run.corrections = ["Type": "typ", "type": "typ"]
    let result = await run.run()
    XCTAssertEqual(result.pasted, "Hello world")
  }

  func testAnOrdinaryQuestionIsNotPasted() async {
    var run = DictationRun()
    run.cloudHeard = "what is on my calendar tomorrow"
    run.localHeard = "what is on my calendar tomorrow"
    let result = await run.run()
    XCTAssertNil(result.pasted)
    XCTAssertEqual(result.source, .cloudBatch)
  }

  func testTypescriptIsAQuestionNotADictation() async {
    var run = DictationRun()
    run.cloudHeard = "typescript generics, explain them"
    let result = await run.run()
    XCTAssertNil(result.pasted)
  }

  /// A hold that was only room tone reaches no recognizer at all.
  func testASilentHoldNeverReachesARecognizer() async {
    var run = DictationRun()
    run.chunks = [roomTone(4)]
    run.cloudHeard = "type invented words"
    run.localHeard = "Thank you."
    let result = await run.run()
    XCTAssertNil(result.pasted)
    XCTAssertEqual(result.decodeCount, 0)
  }

  /// The on-device model answers a breath with an invented phrase, so a hold
  /// with less than half a second of voice in it is not decoded either.
  func testABreathNeverReachesARecognizer() async {
    var run = DictationRun()
    run.chunks = [roomTone(1), voice(0.2), roomTone(1)]
    run.localHeard = "Thank you."
    let result = await run.run()
    XCTAssertNil(result.pasted)
    XCTAssertEqual(result.decodeCount, 0)
  }

  /// A hold past the turn audio cap still delivers what it heard. A truncated
  /// sentence beats a discarded one, and the caller logs the truncation.
  func testAHoldPastTheCapStillPastesWhatItHeard() async {
    var run = DictationRun()
    run.maxBytes = voice(2).count
    run.chunks = [voice(10)]
    run.cloudHeard = "type the first part of a long dictation"
    let result = await run.run()
    XCTAssertEqual(result.pasted, "The first part of a long dictation")
    XCTAssertTrue(result.truncated)
    XCTAssertEqual(result.heldSeconds, 2, accuracy: 0.01)
  }

  func testATurnNeitherRecognizerHeardPastesNothing() async {
    var run = DictationRun()
    run.cloudHeard = nil
    run.localHeard = nil
    let result = await run.run()
    XCTAssertNil(result.pasted)
    XCTAssertEqual(result.degradation, .empty)
  }

  /// A bare wake word must leave nothing behind.
  func testABareWakeWordPastesNothing() async {
    var run = DictationRun()
    run.cloudHeard = "type"
    let result = await run.run()
    XCTAssertNil(result.pasted)
  }

  /// Whatever a recognizer returns for the fillers, a hold that was only
  /// hesitation leaves the document alone.
  func testAHoldOfNothingButFillersPastesNothing() async {
    var run = DictationRun()
    run.cloudHeard = "type um uh"
    let result = await run.run()
    XCTAssertNil(result.pasted)
  }
}
