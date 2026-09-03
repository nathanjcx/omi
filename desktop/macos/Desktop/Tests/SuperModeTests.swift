import CoreGraphics
import Foundation
import VoiceTurnDomain
import XCTest

@testable import Omi_Computer

/// **Super Mode's promise is a negative one**: while it is on, an answer comes from Gemini using
/// only what has been said since the switch, plus a screenshot taken now. Everything else — the
/// user's memories, the chat history that existed a second earlier, tools, past frames — must not be
/// in the request.
///
/// A negative like that is invisible in the UI: an answer that quietly used a memory looks exactly
/// like one that did not. So it is asserted on the wire body, which is where a regression would
/// actually show up, and the body builder is pure for that reason.
@MainActor
final class SuperModeTests: XCTestCase {

  private func parts(of body: Data) throws -> [[String: Any]] {
    let json = try XCTUnwrap(
      JSONSerialization.jsonObject(with: body) as? [String: Any])
    return try XCTUnwrap(json["contents"] as? [[String: Any]])
  }

  // MARK: - The context rule

  private static func userTurn(_ text: String, image: Data? = nil) -> SuperModeController.Turn {
    .init(user: true, text: text, image: image?.base64EncodedString())
  }

  private static func modelTurn(_ text: String) -> SuperModeController.Turn {
    .init(user: false, text: text, image: nil)
  }

  /// The whole feature in one assertion: a fresh session sends the question and the screenshot, and
  /// nothing that came before the switch.
  func testAFreshSessionSendsOnlyTheQuestionAndTheScreenshot() throws {
    let body = try SuperModeController.requestBody(
      turns: [Self.userTurn("what is this error", image: Data([0xFF, 0xD8, 0xFF]))])

    let contents = try parts(of: body)
    XCTAssertEqual(contents.count, 1, "a first turn carries no history at all")
    let turnParts = try XCTUnwrap(contents[0]["parts"] as? [[String: Any]])
    XCTAssertEqual(turnParts.last?["text"] as? String, "what is this error")
    let inline = try XCTUnwrap(turnParts.first?["inline_data"] as? [String: Any])
    XCTAssertEqual(inline["mime_type"] as? String, "image/jpeg")
    XCTAssertEqual(inline["data"] as? String, Data([0xFF, 0xD8, 0xFF]).base64EncodedString())
  }

  /// **Only the newest attachment goes over the wire.** An old frame is the expensive half of the
  /// payload and is almost never what the current question is about — and a stale screenshot is
  /// worse than none, because the model answers confidently about a screen that has since changed.
  func testOnlyTheNewestAttachmentIsSent() throws {
    let body = try SuperModeController.requestBody(turns: [
      Self.userTurn("what am I looking at", image: Data([0x01])),
      Self.modelTurn("a stack trace"),
      Self.userTurn("which line failed", image: Data([0x02])),
    ])

    let contents = try parts(of: body)
    XCTAssertEqual(contents.map { $0["role"] as? String }, ["user", "model", "user"])

    let older = contents[0..<2].flatMap { $0["parts"] as? [[String: Any]] ?? [] }
    XCTAssertTrue(
      older.allSatisfy { $0["inline_data"] == nil },
      "an older turn replayed its screenshot; only the newest frame may be sent")
    XCTAssertEqual(
      older.compactMap { $0["text"] as? String },
      [
        "what am I looking at", "a stack trace",
      ])

    let newest = try XCTUnwrap(contents[2]["parts"] as? [[String: Any]])
    let inline = try XCTUnwrap(newest.first?["inline_data"] as? [String: Any])
    XCTAssertEqual(inline["data"] as? String, Data([0x02]).base64EncodedString())
  }

  /// A screen that could not be captured (screen-recording permission off) still asks the question
  /// rather than sending an empty image part Gemini would reject.
  func testAMissingScreenshotStillSendsTheQuestion() throws {
    let contents = try parts(of: SuperModeController.requestBody(turns: [Self.userTurn("hi")]))
    let turnParts = try XCTUnwrap(contents[0]["parts"] as? [[String: Any]])
    XCTAssertEqual(turnParts.count, 1)
    XCTAssertEqual(turnParts[0]["text"] as? String, "hi")
  }

  /// Turns are stored provider-neutrally, so only this function knows Gemini's schema. Storing the
  /// vendor's own message shape means rewriting stored history the day a second provider is added.
  func testTurnsAreSerializedToTheProviderSchemaAtSendTime() throws {
    let contents = try parts(
      of: SuperModeController.requestBody(turns: [
        Self.userTurn("hello"), Self.modelTurn("hi"),
      ]))
    XCTAssertEqual(contents.map { $0["role"] as? String }, ["user", "model"])
  }

  /// Prefill is paid per turn on every request, so the window is a latency control as much as a cost
  /// one. Older turns stay in memory; they just stop being sent.
  func testOnlyTheNewestTurnsAreSent() {
    let controller = SuperModeController()
    for index in 0..<(SuperModeController.contextLimit + 6) {
      controller.appendTurnForTesting(Self.userTurn("q\(index)"))
    }
    let sent = controller.windowed()
    XCTAssertEqual(sent.count, SuperModeController.contextLimit)
    XCTAssertEqual(sent.last?.text, "q\(SuperModeController.contextLimit + 5)")
  }

  /// Turning the mode off has to *forget*. Keeping the transcript so the next session could resume
  /// it is exactly the leaked context the mode rules out — and the user has no way to see it.
  func testSwitchingTheModeOffAndOnAgainForgetsTheSession() {
    let controller = SuperModeController()
    controller.turnOn()
    XCTAssertTrue(controller.isOn)

    controller.turnOff()
    XCTAssertFalse(controller.isOn)
    XCTAssertTrue(controller.turns.isEmpty)

    controller.turnOn()
    XCTAssertTrue(controller.turns.isEmpty, "a new session inherited the last one's transcript")
  }

  // MARK: - Answers and failures

  func testAnAnswerIsReadOutOfTheResponse() throws {
    let data = Data(
      #"{"candidates":[{"content":{"parts":[{"text":"line 42"}]}}]}"#.utf8)
    XCTAssertEqual(try SuperModeController.parseAnswer(data: data, response: nil), "line 42")
  }

  /// The one failure a user can actually fix is a bad key, and Google says so in the body of a 400.
  /// Reporting the status code instead would tell them nothing.
  func testGoogleSErrorMessageIsPreferredOverTheStatusCode() {
    let data = Data(#"{"error":{"message":"API key not valid"}}"#.utf8)
    let response = HTTPURLResponse(
      url: SuperModeController.endpoint, statusCode: 400, httpVersion: nil, headerFields: nil)
    XCTAssertThrowsError(try SuperModeController.parseAnswer(data: data, response: response)) {
      XCTAssertEqual(
        $0 as? SuperModeController.SuperModeError, .api("API key not valid"))
      XCTAssertEqual(SuperModeController.failureText($0), "Gemini: API key not valid")
    }
  }

  /// A body with neither an error nor a candidate (a safety block, a truncated response) must not
  /// read as a successful empty answer — that renders as a blank response bubble.
  func testAnAnswerlessBodyFails() {
    XCTAssertThrowsError(
      try SuperModeController.parseAnswer(data: Data("{}".utf8), response: nil)
    ) {
      XCTAssertEqual($0 as? SuperModeController.SuperModeError, .empty)
    }
  }

  // MARK: - Which turns it takes over

  /// The bolt is drawn in the main composer and the floating bar, so those are the turns Super Mode
  /// may answer. A task-agent or agent-pill turn is scripted work with no way to see the mode is on;
  /// answering it from a screenshot would silently break a background job.
  func testOnlyTheSurfacesThatShowTheBoltAreIntercepted() {
    XCTAssertTrue(ChatProvider.superModeAnswers(.mainChat))
    XCTAssertTrue(ChatProvider.superModeAnswers(.floatingDefault))
    XCTAssertTrue(ChatProvider.superModeAnswers(.floatingVoice))
    XCTAssertFalse(ChatProvider.superModeAnswers(.taskChat("task-1")))
    XCTAssertFalse(ChatProvider.superModeAnswers(.agentPill(UUID())))
  }

  /// The state has to be readable from the composer without hovering anything. The placeholder is
  /// the row's largest text, so it carries the claim — and it must go back afterwards, or turning the
  /// mode off leaves a field still advertising Gemini.
  func testTheComposerPlaceholderNamesTheAssistantThatWillAnswer() {
    XCTAssertEqual(
      QueryHeroBar.placeholderText(superModeOn: true, mode: .answer), "Ask Gemini about this screen…")
    XCTAssertEqual(
      QueryHeroBar.placeholderText(superModeOn: true, mode: .results), "Ask Gemini about this screen…")
    XCTAssertEqual(QueryHeroBar.placeholderText(superModeOn: false, mode: .answer), "Ask a follow-up…")
    XCTAssertEqual(
      QueryHeroBar.placeholderText(superModeOn: false, mode: .results), RewindSearchMetrics.placeholder)
  }

  // MARK: - The voice turn

  /// **Two voices must never answer one spoken question.**
  ///
  /// Push-to-talk is a Gemini Live session that hears the audio *and* answers from inside it. Super
  /// Mode takes over the answering half, so the hub's spoken reply has to be withheld — and it has
  /// to be withheld ahead of the transport's own reasons, because this one is a product decision
  /// that holds regardless of what the transport thinks. An earlier attempt instead moved *capture*
  /// off the hub and push-to-talk stopped producing words at all; nothing here touches the route.
  func testTheHubDoesNotSpeakWhileSuperModeOwnsTheAnswer() {
    XCTAssertEqual(
      RealtimeProviderOutputPresentationPolicy.decide(
        screenGroundingState: .inactive, reducerOutputSuppressed: false, superModeOwnsAnswer: true),
      .suppressSuperModeOwnsAnswer)
    // It outranks the transport's own suppression reasons, so the disposition never reads `.present`
    // for a Super Mode turn no matter what else is true.
    XCTAssertEqual(
      RealtimeProviderOutputPresentationPolicy.decide(
        screenGroundingState: .inactive, reducerOutputSuppressed: true, superModeOwnsAnswer: true),
      .suppressSuperModeOwnsAnswer)
  }

  /// **The handoff waits for the button to come up, and "up" is not one named phase.**
  ///
  /// A provider finalizes a transcript on a long enough pause, so a final transcript mid-hold is an
  /// ordinary event — answering it would cancel the turn in the middle of a sentence. The release
  /// test has to be `!isRecording`: a hub turn lands in `.awaitingResponse` on release while a
  /// transcription turn lands in `.finalizing`, so naming either phase means "only the other route",
  /// and the first version of this guard named the one the hub never reaches.
  func testTheHandoffWaitsForReleaseOnEitherRoute() {
    for held in [VoiceTurnPhase.recording, .lockedRecording, .pendingLockDecision] {
      XCTAssertTrue(held.isRecording, "\(held) is a held button and must not hand off")
    }
    for released in [VoiceTurnPhase.awaitingResponse, .finalizing, .awaitingTools] {
      XCTAssertFalse(
        released.isRecording,
        "\(released) is a released button — a guard that excludes it never fires on that route")
    }
  }

  /// **The handoff cannot depend on a final input-transcript flag, because Gemini never sends one.**
  ///
  /// This is the defect that made typing work and speaking silently do nothing: the trigger was
  /// `isFinal`, and `RealtimeHubSession`'s Gemini branch emits every input-transcript fragment with
  /// `isFinal: false` — only the OpenAI branch has a final. The condition was therefore unreachable
  /// on the provider the app actually runs, the hub answered normally, and every guard returned
  /// silently so the log said nothing at all.
  ///
  /// A static checker, and labelled as such: which literal a call site passes is not observable from
  /// a running session without a live provider socket. It guards the exact assumption that failed.
  func testStaticCheckerGeminiNeverMarksAnInputTranscriptFinal() throws {
    let source = try Self.source("FloatingControlBar/RealtimeHubSession.swift")
    let geminiBranch = try XCTUnwrap(
      source.range(of: "if let it = sc[\"inputTranscription\"]"),
      "the Gemini input-transcription branch moved; re-anchor this checker")
    let emit = try XCTUnwrap(
      source.range(of: "emitTranscript(", range: geminiBranch.upperBound..<source.endIndex))
    let call = source[emit.lowerBound..<source.index(emit.upperBound, offsetBy: 60)]
    XCTAssertTrue(
      call.contains("isFinal: false"),
      "Gemini now marks input transcripts final; the Super Mode handoff may rely on it again")
  }

  private static func source(_ path: String) throws -> String {
    let root = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()  // Tests
      .deletingLastPathComponent()  // Desktop
      .appendingPathComponent("Sources")
    return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
  }

  /// With the mode off, the hub answers exactly as it always has. This is the assertion that would
  /// have failed on the version that broke push-to-talk.
  func testTheHubStillSpeaksNormallyWhenSuperModeIsOff() {
    XCTAssertEqual(
      RealtimeProviderOutputPresentationPolicy.decide(
        screenGroundingState: .inactive, reducerOutputSuppressed: false, superModeOwnsAnswer: false),
      .present)
  }

  /// **The model is a dated fact, and this one already went stale in a user's hands:**
  /// `gemini-2.5-pro` was closed to new callers and every answer came back as Google's upgrade
  /// notice instead. That id must never come back.
  ///
  /// This assertion used to require a *pro*-tier id. It was rewritten deliberately when the pin
  /// moved to `gemini-flash-latest`, on measurement rather than taste: median of three trials on a
  /// real 1280px screenshot, warm-up discarded, put the pro models at 4.61–4.97s to first token and
  /// `gemini-flash-latest` at 1.37s — the same shape the upstream project's own README reports. What
  /// survives is the part that is still true regardless of tier: not the retired id, and a chat
  /// model rather than a TTS or embedding one, which the discovery filter would otherwise reject.
  func testTheModelIsAChatModelAndNotTheRetiredOne() {
    XCTAssertNotEqual(SuperModeController.model, "gemini-2.5-pro")
    for marker in SuperModeController.nonChatModelMarkers {
      XCTAssertFalse(
        SuperModeController.model.contains(marker),
        "\(SuperModeController.model) looks like a \(marker) model, which cannot answer questions")
    }
    XCTAssertTrue(
      SuperModeController.endpoint.absoluteString.hasSuffix(
        "/models/\(SuperModeController.model):generateContent"))
  }

  // MARK: - The conditional expensive step

  /// **The third tier defaults to looking, and that asymmetry is the whole point.** A needless
  /// screenshot costs a few hundred milliseconds; a missing one costs the entire answer — the model
  /// replies that it cannot see the screen and the user has to ask again. A version that defaulted
  /// unmatched questions to `false` is the bug this shape exists to prevent.
  func testAQuestionMatchingNoKeywordStillLooksAtTheScreen() {
    for question in [
      "what am I supposed to do next", "is it done yet", "summarise", "and the second one",
      "does it look right to you", "why",
    ] {
      XCTAssertTrue(
        SuperModeController.needsScreen(question),
        "\(question.debugDescription) matched no keyword and was answered blind")
    }
  }

  func testQuestionsThatPointAtTheScreenAlwaysLook() {
    for question in [
      "what is this error", "read the terminal", "what's wrong here", "what apps do I have open",
    ] {
      XCTAssertTrue(SuperModeController.needsScreen(question), question)
    }
  }

  /// Only plainly self-contained general knowledge skips the capture.
  func testPlainGeneralKnowledgeSkipsTheCapture() {
    for question in ["what is the capital of France", "define entropy", "translate hello to Spanish"] {
      XCTAssertFalse(SuperModeController.needsScreen(question), question)
    }
  }

  /// A question pointing at the screen wins outright even when it also reads as general knowledge —
  /// "explain this error" is about the screen, not about errors.
  func testScreenIntentOutranksTheGeneralKnowledgeHint() {
    XCTAssertTrue(SuperModeController.needsScreen("explain this error"))
    XCTAssertTrue(SuperModeController.needsScreen("how do I fix the code on my screen"))
  }

  // MARK: - Failure handling

  /// SSE endpoints report failures as body content, not as headers. A status check that returns
  /// without draining leaves the one actionable sentence unread on the socket and reports a bare
  /// number instead — which is what the first version did.
  func testTheActionableMessageIsReadOutOfAnErrorBody() {
    let body = Data(#"{"error":{"code":400,"message":"API key not valid"}}"#.utf8)
    XCTAssertEqual(SuperModeController.errorMessage(in: body), "API key not valid")
    XCTAssertNil(SuperModeController.errorMessage(in: Data("not json".utf8)))
    XCTAssertNil(SuperModeController.errorMessage(in: Data(#"{"error":{"message":""}}"#.utf8)))
  }

  // MARK: - Model discovery

  /// Capability alone still admits ids that are never a chat model, and one configured as the
  /// answering model fails at request time complaining about modalities rather than about the model.
  func testTheModelListingKeepsOnlyChatModels() {
    let listing = Data(
      #"""
      {"models":[
        {"name":"models/gemini-flash-latest","supportedGenerationMethods":["generateContent"]},
        {"name":"models/gemini-embedding-001","supportedGenerationMethods":["generateContent"]},
        {"name":"models/gemini-3.1-flash-tts-preview","supportedGenerationMethods":["generateContent"]},
        {"name":"models/gemini-3-pro-image","supportedGenerationMethods":["generateContent"]},
        {"name":"models/text-bison","supportedGenerationMethods":["countTokens"]}
      ]}
      """#.utf8)
    XCTAssertEqual(SuperModeController.chatModels(inListing: listing), ["gemini-flash-latest"])
  }

  /// When the pinned model has disappeared the warning has to name a replacement — this is the
  /// failure that already shipped once, when `gemini-2.5-pro` was closed to new callers.
  func testTheClosestAvailableModelIsSuggested() {
    let available = ["gemini-2.5-flash", "gemini-3.1-pro-preview", "imagen-4"]
    XCTAssertEqual(
      SuperModeController.closest(to: "gemini-3.1-pro", in: available), "gemini-3.1-pro-preview")
  }

  // MARK: - The editable system prompt

  /// What the user writes in the popover is what the model is told. Asserted on the wire body,
  /// because that is the only place the claim is actually true or false.
  func testTheEditedSystemPromptIsWhatReachesTheModel() throws {
    let body = try SuperModeController.requestBody(
      turns: [Self.userTurn("what is this")], systemInstruction: "Reply only in French.")
    let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
    let instruction = try XCTUnwrap(json["system_instruction"] as? [String: Any])
    let parts = try XCTUnwrap(instruction["parts"] as? [[String: Any]])
    XCTAssertEqual(parts.first?["text"] as? String, "Reply only in French.")
  }

  /// **An emptied box means "use the default", never "send nothing".** A screenshot with no system
  /// instruction leaves the model guessing what it is being asked to do with the image, and the
  /// resulting drop in answer quality looks like the mode getting worse for no reason.
  func testAnEmptyPromptFallsBackToTheDefaultRatherThanSendingNothing() {
    let controller = SuperModeController()
    controller.systemInstruction = "   \n  "
    XCTAssertEqual(controller.effectiveSystemInstruction, SuperModeController.defaultSystemInstruction)

    controller.systemInstruction = "Be terse."
    XCTAssertEqual(controller.effectiveSystemInstruction, "Be terse.")
  }

  /// Surrounding whitespace from a paste must not become part of the instruction.
  func testAPastedPromptIsTrimmedBeforeItIsSent() {
    let controller = SuperModeController()
    controller.systemInstruction = "\n  Answer in one sentence.  \n"
    XCTAssertEqual(controller.effectiveSystemInstruction, "Answer in one sentence.")
  }

  /// **Length is shortened by the prompt, never by a token cap**, which truncates mid-sentence
  /// instead of condensing.
  func testLengthIsControlledByThePromptAndNotByATokenCap() throws {
    let body = try SuperModeController.requestBody(turns: [Self.userTurn("hi")])
    let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
    let config = json["generationConfig"] as? [String: Any] ?? [:]
    XCTAssertNil(config["maxOutputTokens"], "a token cap truncates instead of condensing")
    XCTAssertTrue(SuperModeController.defaultSystemInstruction.contains("fewest words"))
  }

  // MARK: - The spoken voice

  /// **Super Mode must sound like Omi, and "like Omi" has exactly one definition in this app.**
  /// `RealtimeHubVoicePolicy` pins Charon on Gemini and cedar on OpenAI so a provider failover
  /// changes the engine and not the person. The first spoken Super Mode answers went out through the
  /// shared playback service, which synthesizes with OpenAI TTS in whichever voice Settings names —
  /// Shimmer by default — so holding the mic answered in a different voice than it had a moment
  /// earlier. Reading the name from the policy rather than restating it is what stops that recurring.
  func testTheSpokenVoiceIsReadFromTheOneVoiceAuthority() {
    XCTAssertEqual(SuperModeVoice.voiceName, RealtimeHubVoicePolicy.voiceName(for: .gemini))
    XCTAssertEqual(SuperModeVoice.voiceName, "Charon")
  }

  func testTheSynthesisRequestAsksForThatVoiceAndForAudio() throws {
    let body = try SuperModeVoice.requestBody(text: "Hello.")
    let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
    let config = try XCTUnwrap(json["generationConfig"] as? [String: Any])
    XCTAssertEqual(config["responseModalities"] as? [String], ["AUDIO"])
    let speech = try XCTUnwrap(config["speechConfig"] as? [String: Any])
    let voice = try XCTUnwrap(speech["voiceConfig"] as? [String: Any])
    let prebuilt = try XCTUnwrap(voice["prebuiltVoiceConfig"] as? [String: Any])
    XCTAssertEqual(prebuilt["voiceName"] as? String, RealtimeHubVoicePolicy.voiceName(for: .gemini))
  }

  /// The API has used both spellings of the inline-audio key across versions, and accepting only one
  /// is a bug with no symptom except silence.
  func testAudioIsReadUnderEitherSpellingOfTheInlineDataKey() {
    let pcm = Data([0x01, 0x02, 0x03, 0x04]).base64EncodedString()
    for key in ["inlineData", "inline_data"] {
      let payload = Data(#"{"candidates":[{"content":{"parts":[{"\#(key)":{"data":"\#(pcm)"}}]}}]}"#.utf8)
      XCTAssertEqual(
        SuperModeVoice.pcm(fromResponse: payload), Data([0x01, 0x02, 0x03, 0x04]),
        "audio under \(key) was not read")
    }
  }

  // MARK: - Chunking (speech starts on sentence one)

  func testACompletedSentenceIsSpokenWithoutWaitingForTheRest() {
    var buffer = "You are looking at a code editor. And a term"
    XCTAssertEqual(
      SuperModeVoice.nextChunk(from: &buffer, isFinal: false), "You are looking at a code editor.")
    XCTAssertEqual(buffer, " And a term")
    XCTAssertNil(SuperModeVoice.nextChunk(from: &buffer, isFinal: false))
  }

  /// A decimal or a model name is not the end of a sentence. Breaking there speaks "gemini dash
  /// three." as its own utterance and drops the pause where a real one belonged.
  func testAFullStopInsideANumberOrAModelNameIsNotASentenceEnd() {
    var buffer = "It costs 1.50 on gemini-3.1-pro and that is all"
    XCTAssertNil(SuperModeVoice.nextChunk(from: &buffer, isFinal: false))
  }

  func testTheFinalFragmentIsSpokenEvenWithoutTerminalPunctuation() {
    var buffer = "and that is the whole answer"
    XCTAssertEqual(
      SuperModeVoice.nextChunk(from: &buffer, isFinal: true), "and that is the whole answer")
    XCTAssertNil(SuperModeVoice.nextChunk(from: &buffer, isFinal: true))
  }

  /// Prose with no punctuation at all would otherwise hold every later sentence behind it — but the
  /// break lands on a word boundary, because cutting mid-word makes the synthesizer pronounce the
  /// fragment as if it were a word.
  func testAnUnpunctuatedRunOnIsBrokenAtAWordBoundaryUnderTheCap() throws {
    var buffer = String(repeating: "word ", count: 200)
    let chunk = try XCTUnwrap(SuperModeVoice.nextChunk(from: &buffer, isFinal: false))
    XCTAssertLessThanOrEqual(chunk.count, SuperModeVoice.maxChunkCharacters)
    XCTAssertGreaterThan(chunk.count, SuperModeVoice.maxChunkCharacters - 10, "broke far too early")
    XCTAssertTrue(chunk.hasSuffix("word"), "the break split a word: \(chunk.suffix(12).debugDescription)")
  }

  /// **The opening chunk breaks sooner than the rest.** Nothing is playing yet, so its round trip is
  /// the only thing between the answer appearing and the answer being heard; every later chunk is
  /// already overlapping one that is playing.
  func testTheFirstChunkBreaksSoonerThanLaterOnes() throws {
    var first = String(repeating: "word ", count: 200)
    let opening = try XCTUnwrap(SuperModeVoice.nextChunk(from: &first, isFinal: false, isFirst: true))
    XCTAssertLessThanOrEqual(opening.count, SuperModeVoice.firstChunkCharacters)

    var later = String(repeating: "word ", count: 200)
    let subsequent = try XCTUnwrap(
      SuperModeVoice.nextChunk(from: &later, isFinal: false, isFirst: false))
    XCTAssertGreaterThan(subsequent.count, opening.count)
  }

  // MARK: - Streaming (time to first token)

  /// **The endpoint has to be the SSE one, or nothing streams.** `:generateContent` still generates
  /// the whole answer before replying, so the user waits out the entire completion to see the first
  /// character — the exact latency this path is tuned against.
  func testTheRequestGoesToTheStreamingEndpoint() {
    let url = SuperModeController.streamEndpoint.absoluteString
    XCTAssertTrue(url.contains(":streamGenerateContent"), url)
    XCTAssertTrue(url.contains("alt=sse"), "without alt=sse the server buffers the whole response")
  }

  /// Thinking happens before the first token, so it is charged entirely to the silence the user is
  /// waiting through. Nested under `thinkingConfig`, because flat is a 400 — the API rejects
  /// `thinkingLevel` as an unknown name, and shipping that made every send pay a wasted round trip.
  func testThinkingIsTurnedDownAndNestedWhereTheAPITakesIt() throws {
    let body = try SuperModeController.requestBody(turns: [Self.userTurn("what is this")])
    let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
    let config = try XCTUnwrap(json["generationConfig"] as? [String: Any])
    let thinking = try XCTUnwrap(config["thinkingConfig"] as? [String: Any])
    XCTAssertEqual(thinking["thinkingLevel"] as? String, "low")
    XCTAssertNil(config["thinkingLevel"], "a flat thinkingLevel is rejected as an unknown name")
  }

  /// The retry that follows a rejected speed hint must send no hint at all, or it fails identically.
  func testTheRetryDropsTheSpeedHintEntirely() throws {
    let body = try SuperModeController.requestBody(turns: [Self.userTurn("hi")], fast: false)
    let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
    XCTAssertNil(json["generationConfig"])
  }

  func testTextFragmentsAreReadOutOfTheEventStream() {
    let line = #"data: {"candidates":[{"content":{"parts":[{"text":"Ban"}]}}]}"#
    XCTAssertEqual(SuperModeController.deltaFromEventLine(line), .text("Ban"))
  }

  /// **Every non-text line must be ignored, not mistaken for an empty answer.** A real stream is
  /// mostly blank separators and bookkeeping; a parser returning "" for those truncates the reply at
  /// the first one.
  func testStreamBookkeepingLinesAreIgnored() {
    for line in ["", "\r", ": keep-alive", "event: message", "data: [DONE]", "data:   "] {
      XCTAssertNil(
        SuperModeController.deltaFromEventLine(line),
        "\(line.debugDescription) was read as answer content")
    }
  }

  /// An error can arrive mid-stream after a 200 — a quota trip on a later chunk.
  func testAMidStreamErrorSurfacesGooglesMessage() {
    let line = #"data: {"error":{"message":"You exceeded your current quota"}}"#
    XCTAssertEqual(
      SuperModeController.deltaFromEventLine(line), .failure("You exceeded your current quota"))
  }

  /// Prefill scales with image area, so the screenshot is the largest single lever on first-token
  /// latency after the model itself — and a display already under the cap must not be resampled.
  func testTheScreenshotIsShrunkForPrefillButNeverUpscaled() throws {
    let retina = try XCTUnwrap(Self.image(width: 3024, height: 1964))
    let shrunk = try XCTUnwrap(
      SuperModeController.downscale(retina, longEdge: SuperModeController.screenshotLongEdge))
    XCTAssertEqual(shrunk.width, SuperModeController.screenshotLongEdge)
    XCTAssertEqual(shrunk.height, 831, "aspect ratio was not preserved")

    let small = try XCTUnwrap(Self.image(width: 800, height: 600))
    XCTAssertNil(
      SuperModeController.downscale(small, longEdge: SuperModeController.screenshotLongEdge),
      "an image already under the cap was resampled for no benefit")
  }

  private static func image(width: Int, height: Int) -> CGImage? {
    CGContext(
      data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    )?.makeImage()
  }

}
