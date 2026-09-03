import Foundation
import SwiftUI

/// **Super Mode — Gemini, and nothing else.**
///
/// An ordinary Omi answer is assembled from the user's memories, their whole chat history, and
/// whatever tools the kernel decides to run. Super Mode is the deliberate opposite: while it is on,
/// a question is answered by Gemini from exactly two things — what has been said *since the mode
/// was switched on*, and a screenshot taken at ask time.
///
/// The context is built here rather than filtered out downstream, because "no other context" is the
/// entire product promise and a downstream filter is one prompt change away from quietly putting
/// the context back. Nothing in this file reads `ChatProvider`, `APIClient`, or the kernel journal.
///
/// The key is the user's own: Super Mode calls Google directly, so it never spends the account's
/// proxied Gemini budget and never routes the screenshot through Omi's backend.
@MainActor
final class SuperModeController: ObservableObject {
  static let shared = SuperModeController()

  /// **The single largest lever on first-token latency, and it is not close.**
  ///
  /// Measured on this machine against a real 1280px screenshot, median of three trials after a
  /// discarded warm-up, every other setting held at the tuned values below:
  ///
  ///   gemini-3.1-pro-preview    4.97s      gemini-3.8-flash          1.62s
  ///   gemini-pro-latest         4.61s      gemini-flash-latest       1.37s
  ///   gemini-3.1-flash-lite     1.16s      gemini-flash-lite-latest  0.92s
  ///
  /// Two things fall out of that table. A pro model costs roughly four seconds of silence before the
  /// first word, which is most of the wait on a question whose answer is one sentence. And the
  /// floating aliases beat their pinned equivalents — `flash-lite-latest` by a quarter second over
  /// `gemini-3.1-flash-lite` — so pinning a version buys reproducibility at a measurable cost, and
  /// buys nothing against the model being retired, which happened here anyway.
  ///
  /// `gemini-flash-latest` is the balance point: five times faster to first token than the pro model
  /// it replaces, and still a full flash model rather than the lite tier, which matters because this
  /// mode's job is reading dense UI text. If you want the last half second, `gemini-flash-lite-latest`
  /// measured 0.92s — a one-word change here, paid for in reading accuracy.
  nonisolated static let model = "gemini-flash-latest"

  static let apiKeyDefaultsKey = "super_mode_gemini_api_key"
  static let systemInstructionDefaultsKey = "super_mode_system_instruction"

  // MARK: - Latency configuration
  //
  // **The tuned quantity is time to first token, not total completion time.** A Super Mode answer is
  // read as it arrives, so the wait that matters is the one before anything appears; a longer tail
  // costs nothing the user perceives. Every constant below buys the front of the response.

  /// Gemini 3.x models reason before answering by default, and that thinking is pure pre-token
  /// latency — it lands entirely inside the silence the user is waiting through. "What is on this
  /// screen" does not need it.
  static let thinkingLevel = "low"

  /// Long edge of the screenshot, in pixels. Prefill scales with image tokens, and image tokens
  /// scale with area, so this is the largest single lever on first-token latency. Retina full-frame
  /// screenshots are several megapixels for a question usually answerable from layout and headings.
  nonisolated static let screenshotLongEdge = 1280

  /// JPEG quality for that screenshot. Lower than the 0.7 the rest of the app uses: at this edge
  /// length the artefacts land below what the model reads, and the bytes are uploaded before any
  /// token can come back.
  nonisolated static let screenshotQuality: CGFloat = 0.5

  /// **Length is controlled by the prompt, never by `maxOutputTokens`.** A token cap truncates a
  /// reply mid-sentence; an instruction makes the model condense, which is the thing actually wanted.
  ///
  /// The wording is deliberate and was arrived at by measurement rather than taste: "lead with the
  /// answer in one sentence" reads to a model as permission to spend a sentence on preamble, and
  /// padded every reply. Naming what *not* to do — restate, describe, repeat — is what removes it.
  ///
  /// It is the *default*, not the value: the user can rewrite it in the settings popover, and it
  /// stays the fallback for an empty box, because sending no system instruction at all makes the
  /// model guess what the screenshot is for.
  static let defaultSystemInstruction =
    "Answer only what was asked, in the fewest words that are still specific. "
    + "Start with the answer itself \u{2014} never restate the question, and never describe the "
    + "screen unless that is what was asked. Never repeat anything you already said."

  static let missingKeyMessage =
    "Super Mode needs a Gemini API key. Hold the bolt next to the mic and paste one in."

  /// **One conversation turn, stored provider-neutrally and serialized per API at send time.**
  ///
  /// Not the provider's own message shape: role names, attachment shapes and where the system prompt
  /// goes all differ between APIs, so storing one vendor's schema means rewriting history the day a
  /// second provider is added. `image` is base64 JPEG, carried so the newest one can be found — see
  /// `requestBody`, which sends only that one.
  struct Turn: Equatable {
    let user: Bool
    var text: String
    var image: String?
  }

  /// How many turns go over the wire. Everything older stays in memory for the session but is not
  /// sent: prefill is paid per turn on every request, and the eighth-previous exchange almost never
  /// changes the answer to the current question.
  static let contextLimit = 8

  /// The TLS handshake sits on the critical path of the first request against a cold host, and it is
  /// pure dead time. `warm()` opens the connection early; this throttle keeps a focused field from
  /// firing one per keystroke.
  static let warmThrottleSeconds: TimeInterval = 25

  enum SuperModeError: Error, Equatable {
    case api(String)
    case http(Int)
    case empty
    /// A 400 on a request that carried the speed hint. Not surfaced to the user: it means "retry
    /// once without it", and only a second failure is a real error.
    case speedHintRejected
  }

  @Published private(set) var isOn = false
  /// When the current session started, so the UI can say how long the mode has been on. `nil`
  /// exactly when `isOn` is false.
  @Published private(set) var startedAt: Date?
  @Published var isPanelOpen = false
  @Published var apiKey: String {
    didSet { UserDefaults.standard.set(apiKey, forKey: Self.apiKeyDefaultsKey) }
  }
  /// What the user has written in the popover, verbatim — including empty, which is a state the box
  /// has to be able to hold while it is being cleared and retyped. `effectiveSystemInstruction` is
  /// what actually goes on the wire.
  @Published var systemInstruction: String {
    didSet { UserDefaults.standard.set(systemInstruction, forKey: Self.systemInstructionDefaultsKey) }
  }

  /// The instruction the request carries. An emptied box means "give me the default back" rather
  /// than "send nothing": a screenshot with no instruction is a prompt the model has to guess at,
  /// and the failure looks like the mode getting worse for no reason.
  var effectiveSystemInstruction: String {
    let written = systemInstruction.trimmingCharacters(in: .whitespacesAndNewlines)
    return written.isEmpty ? Self.defaultSystemInstruction : written
  }

  private(set) var turns: [Turn] = []

  /// One shared, keep-alive session for warm-up, model discovery and the real request, so the
  /// connection `warm()` opens is the one the answer travels over. Separate sessions each get their
  /// own pool and the handshake is paid a second time.
  private let session: URLSession
  private var lastWarmedAt = Date.distantPast

  init(session: URLSession = .shared) {
    self.session = session
    self.apiKey = UserDefaults.standard.string(forKey: Self.apiKeyDefaultsKey) ?? ""
    // Seeded with the default rather than blank, so the box shows what is actually being sent and
    // the user edits a real prompt instead of writing one from nothing.
    self.systemInstruction =
      UserDefaults.standard.string(forKey: Self.systemInstructionDefaultsKey)
      ?? Self.defaultSystemInstruction
  }

  // MARK: - Mode

  func toggle() {
    isOn ? turnOff() : turnOn()
  }

  func turnOn() {
    // Clearing on *both* edges, not just on the way in: a session's transcript must not survive to
    // be read by the next one, which would be exactly the leaked context this mode rules out.
    turns = []
    startedAt = Date()
    isOn = true
    // Switching the mode on is the strongest signal a request is coming: open the connection and
    // check the pinned model now, while the user is still deciding what to ask.
    warm()
    Task { await validateConfiguredModel() }
  }

  func turnOff() {
    turns = []
    startedAt = nil
    isOn = false
  }

  // MARK: - Answering

  /// Screenshot if the question needs one, ask Gemini, stream the answer back, remember the turn.
  ///
  /// **It streams, and the streaming is the point.** The non-streaming endpoint holds the whole
  /// response until the last token is generated, so the user waits out the entire completion before
  /// seeing a character. `onDelta` is called on the main actor with each fragment as it lands.
  ///
  /// Never throws: the caller renders whatever comes back, and a swallowed error there would be a
  /// spinner that never resolves.
  @discardableResult
  func answer(to question: String, onDelta: @MainActor @escaping (String) -> Void = { _ in }) async
    -> String
  {
    let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !key.isEmpty else { return Self.missingKeyMessage }

    let startedAt = Date()
    let wantsScreen = Self.needsScreen(question)
    let screenshot =
      wantsScreen ? await Task.detached { Self.captureScreenshot() }.value : nil

    // Appended before the request so the model sees this question in the same shape as every past
    // one. If the request fails it is rolled back below — a dangling user turn with no reply poisons
    // the next request's history.
    turns.append(
      Turn(user: true, text: question, image: screenshot?.base64EncodedString()))

    var retriedWithoutSpeedHint = false
    do {
      var result: StreamResult
      do {
        result = try await stream(key: key, fast: true, onDelta: onDelta)
      } catch SuperModeError.speedHintRejected {
        // A model that will not take the speed hint gets exactly one plain retry. Without this the
        // hint is a hard failure on any model that has not adopted it.
        retriedWithoutSpeedHint = true
        log("SuperMode: model rejected the speed hint — retrying once without it")
        result = try await stream(key: key, fast: false, onDelta: onDelta)
      }
      turns.append(Turn(user: false, text: result.text, image: nil))
      Self.logRequest(
        firstTokenMs: result.firstTokenMs, totalMs: Int(Date().timeIntervalSince(startedAt) * 1000),
        requestBytes: result.requestBytes, turnsSent: result.turnsSent,
        retriedWithoutConfig: retriedWithoutSpeedHint, screenshot: wantsScreen, failed: false)
      return result.text
    } catch {
      // Roll the question back out of history: a turn with no answer would be replayed as context
      // on the next request, and the model would answer it a second time.
      if turns.last?.user == true { turns.removeLast() }
      // Never log the request itself: it carries the key and a picture of the user's screen.
      log("SuperMode: Gemini request failed (\(Self.failureText(error)))")
      Self.logRequest(
        firstTokenMs: nil, totalMs: Int(Date().timeIntervalSince(startedAt) * 1000),
        requestBytes: 0, turnsSent: 0, retriedWithoutConfig: retriedWithoutSpeedHint,
        screenshot: wantsScreen, failed: true)
      return "⚠️ \(Self.failureText(error))"
    }
  }

  struct StreamResult {
    let text: String
    let firstTokenMs: Int
    let requestBytes: Int
    let turnsSent: Int
  }

  /// One streamed request. Throws `.speedHintRejected` when the caller should retry plainly.
  private func stream(
    key: String, fast: Bool, onDelta: @MainActor @escaping (String) -> Void
  ) async throws -> StreamResult {
    let sent = windowed()
    let body = try Self.requestBody(
      turns: sent, systemInstruction: effectiveSystemInstruction, fast: fast)

    var request = URLRequest(url: Self.streamEndpoint)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    // The key travels as a header, not the `?key=` query parameter Google's samples use: a URL is
    // the one part of a request that reaches logs, crash reports and proxies in the clear.
    request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
    request.timeoutInterval = 180
    request.httpBody = body

    let startedAt = Date()
    let (stream, response) = try await session.bytes(for: request)

    // **Drain the body before deciding anything.** An SSE endpoint reports failures as body content,
    // not as headers, so a status check that returns without reading leaves the one actionable
    // sentence — "API key not valid", "quota exceeded" — unread on the socket. The first version of
    // this threw on the status code alone and reported a bare number.
    if let status = (response as? HTTPURLResponse)?.statusCode, !(200..<300).contains(status) {
      var raw = Data()
      for try await byte in stream { raw.append(byte) }
      if fast, status == 400 { throw SuperModeError.speedHintRejected }
      if let message = Self.errorMessage(in: raw) { throw SuperModeError.api(message) }
      throw SuperModeError.http(status)
    }

    var full = ""
    var firstTokenMs = 0
    for try await line in stream.lines {
      guard let delta = Self.deltaFromEventLine(line) else { continue }
      switch delta {
      case .text(let fragment):
        if full.isEmpty { firstTokenMs = Int(Date().timeIntervalSince(startedAt) * 1000) }
        full += fragment
        onDelta(fragment)
      case .failure(let message):
        throw SuperModeError.api(message)
      }
    }
    guard !full.isEmpty else { throw SuperModeError.empty }
    return StreamResult(
      text: full, firstTokenMs: firstTokenMs, requestBytes: body.count, turnsSent: sent.count)
  }

  // MARK: - History

  /// Only the newest `contextLimit` turns are sent. Older ones stay in memory for the session but
  /// cost nothing per request.
  func windowed() -> [Turn] { Array(turns.suffix(Self.contextLimit)) }

  func clearHistory() { turns = [] }

  /// Seam for tests that need a populated history without a network round trip.
  func appendTurnForTesting(_ turn: Turn) { turns.append(turn) }

  // MARK: - The conditional expensive step

  /// **Default to looking.** Capturing and uploading a screenshot costs a few hundred milliseconds;
  /// *not* capturing one when the question needed it costs the whole answer — the model replies that
  /// it cannot see the screen, and the user has to ask again.
  ///
  /// So the tiers are asymmetric on purpose: anything that points at the screen wins outright,
  /// anything that is plainly self-contained general knowledge skips the capture, and **everything
  /// else looks**. A version that defaulted the third tier to false is the bug this shape exists to
  /// prevent — a question matching no keyword silently became a blind answer.
  nonisolated static func needsScreen(_ question: String) -> Bool {
    let text = " " + question.lowercased() + " "
    let aboutScreen = [
      "screen", "this", "that", "these", "those", " here", "above", "below", "highlight",
      "selected", "visible", "showing", "looking at", " my ", " i have", " im using",
      " i'm using", "error", "the code", "the terminal", "the window", "the page",
      "what's wrong", "whats wrong", " read ", " fix ", " see ", " open", "running", "installed",
    ]
    if aboutScreen.contains(where: { text.contains($0) }) { return true }

    let generalKnowledge = [
      "explain ", "write a ", "write me ", "define ", "how do i ", "how to ", "what does ",
      " mean", "convert ", "translate ", "capital of", "who is ", "difference between",
      "example of",
    ]
    if generalKnowledge.contains(where: { text.contains($0) }) { return false }

    return true  // when in doubt, look
  }

  // MARK: - Connection warm-up

  /// Opens the TLS connection before the request that needs it, so the handshake is off the critical
  /// path. Throwaway: the response is discarded and a failure is meaningless. Called when a request
  /// becomes likely — the mode switching on, the settings popover opening — and throttled so a
  /// focused field cannot fire one per keystroke.
  func warm() {
    guard Date().timeIntervalSince(lastWarmedAt) > Self.warmThrottleSeconds else { return }
    lastWarmedAt = Date()
    var request = URLRequest(url: Self.warmURL)
    request.httpMethod = "HEAD"
    request.timeoutInterval = 5
    session.dataTask(with: request).resume()
  }

  // MARK: - Model discovery

  /// Ids that are never a chat model, however they are named. Filtering by capability alone still
  /// admits these on some accounts, and a TTS or embedding id configured as the answering model
  /// fails at request time with a message about modalities rather than about the model.
  nonisolated static let nonChatModelMarkers = [
    "embedding", "aqa", "image", "transcribe", "learnlm", "realtime", "audio", "tts",
    "moderation", "search", "instruct",
  ]

  /// The chat-capable models this key can actually call.
  static func availableModels(key: String, session: URLSession = .shared) async -> [String] {
    guard let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models?pageSize=200")
    else { return [] }
    var request = URLRequest(url: url)
    request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
    request.timeoutInterval = 20
    guard let (data, _) = try? await session.data(for: request) else { return [] }
    return chatModels(inListing: data)
  }

  /// Pure, so the filter is testable without a network.
  nonisolated static func chatModels(inListing data: Data) -> [String] {
    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let models = json["models"] as? [[String: Any]]
    else { return [] }
    return models.compactMap { entry -> String? in
      guard let name = entry["name"] as? String,
        let methods = entry["supportedGenerationMethods"] as? [String],
        methods.contains("generateContent")
      else { return nil }
      let id = name.replacingOccurrences(of: "models/", with: "")
      guard !nonChatModelMarkers.contains(where: { id.contains($0) }) else { return nil }
      return id
    }
  }

  /// **Warns loudly when the pinned model has disappeared.** This exact failure already shipped
  /// once: `gemini-2.5-pro` was closed to new callers and every answer came back as Google's upgrade
  /// notice instead. A model id is a dated fact, and the first person to find out should not be the
  /// user mid-question.
  func validateConfiguredModel() async {
    let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !key.isEmpty else { return }
    let ids = await Self.availableModels(key: key, session: session)
    guard !ids.isEmpty else { return }
    if ids.contains(Self.model) {
      log("SuperMode: model \(Self.model) is available (\(ids.count) chat models on this key)")
    } else {
      log(
        "SuperMode: WARNING configured model \(Self.model) is NOT available on this key — "
          + "answers will fail. Closest available: \(Self.closest(to: Self.model, in: ids) ?? "none")")
    }
  }

  /// Best replacement suggestion: the available id sharing the longest prefix with the missing one.
  nonisolated static func closest(to model: String, in ids: [String]) -> String? {
    ids.max(by: { sharedPrefix($0, model) < sharedPrefix($1, model) })
  }

  private nonisolated static func sharedPrefix(_ a: String, _ b: String) -> Int {
    zip(a, b).prefix(while: { $0 == $1 }).count
  }

  // MARK: - Instrumentation

  /// One structured line per request. Shape only — never the question, the answer, or the key.
  nonisolated static func logRequest(
    firstTokenMs: Int?, totalMs: Int, requestBytes: Int, turnsSent: Int,
    retriedWithoutConfig: Bool, screenshot: Bool, failed: Bool
  ) {
    log(
      "SuperMode: model=\(model) first_token_ms=\(firstTokenMs.map(String.init) ?? "-") "
        + "total_ms=\(totalMs) request_bytes=\(requestBytes) turns_sent=\(turnsSent) "
        + "retried_without_config=\(retriedWithoutConfig) screenshot=\(screenshot) "
        + "outcome=\(failed ? "failed" : "ok")")
  }

  /// A screenshot sized for latency rather than for fidelity — see `screenshotLongEdge`.
  nonisolated static func captureScreenshot() -> Data? {
    guard let image = ScreenCaptureManager.captureScreenImage() else { return nil }
    let scaled = downscale(image, longEdge: screenshotLongEdge) ?? image
    return ScreenCaptureManager.jpegData(from: scaled, quality: screenshotQuality)
  }

  /// Returns `nil` when the image already fits, so a small display is never resampled for nothing.
  nonisolated static func downscale(_ image: CGImage, longEdge: Int) -> CGImage? {
    let width = image.width
    let height = image.height
    guard max(width, height) > longEdge, width > 0, height > 0 else { return nil }
    let scale = Double(longEdge) / Double(max(width, height))
    let targetWidth = Swift.max(1, Int((Double(width) * scale).rounded()))
    let targetHeight = Swift.max(1, Int((Double(height) * scale).rounded()))
    guard
      let context = CGContext(
        data: nil, width: targetWidth, height: targetHeight, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
    else { return nil }
    // Dense UI text is the thing the model has to read; nearest-neighbour turns it to noise.
    context.interpolationQuality = .high
    context.draw(image, in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
    return context.makeImage()
  }

  // MARK: - Wire format (pure, so the context rule is testable without a network)

  /// Force-unwraps below are safe: the components are compile-time constants, and a nil would mean
  /// the model name literal stopped being a valid path segment.
  static var endpoint: URL {
    URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent")!
  }

  /// The streaming endpoint. `alt=sse` is what makes the response arrive as `data:` events instead
  /// of one buffered JSON array — without it the server still streams internally and the client
  /// still waits for the whole thing.
  /// The API host, for the throwaway warm-up request.
  static var warmURL: URL {
    URL(string: "https://generativelanguage.googleapis.com/")!
  }

  static var streamEndpoint: URL {
    URL(
      string:
        "https://generativelanguage.googleapis.com/v1beta/models/\(model):streamGenerateContent?alt=sse"
    )!
  }

  /// Serializes the neutral turns into Gemini's schema at send time.
  ///
  /// **Only the newest attachment is sent.** Older turns keep their text and lose their image: past
  /// frames are the expensive part of the payload and are almost never what the current question is
  /// about, and a stale screenshot is worse than none — the model answers confidently about a screen
  /// that has since changed.
  static func requestBody(
    turns: [Turn],
    systemInstruction: String = defaultSystemInstruction,
    fast: Bool = true
  ) throws -> Data {
    let newestImage = turns.lastIndex(where: { $0.image != nil })
    let contents: [[String: Any]] = turns.enumerated().map { index, turn in
      var parts: [[String: Any]] = []
      if let image = turn.image, index == newestImage {
        parts.append(["inline_data": ["mime_type": "image/jpeg", "data": image]])
      }
      parts.append(["text": turn.text])
      return ["role": turn.user ? "user" : "model", "parts": parts]
    }
    var payload: [String: Any] = [
      "contents": contents,
      "system_instruction": ["parts": [["text": systemInstruction]]],
    ]
    if fast {
      // Thinking happens before the first token, so it is charged entirely to the wait this whole
      // path is tuned to shorten.
      //
      // Nested under `thinkingConfig`, which is where the API actually takes it — as a sibling of
      // `temperature` it is rejected outright with "Unknown name", and the first version of this
      // shipped that way and turned every answer into a 400. The neighbouring `thinkingBudget: 0`
      // spelling is not an option either: this model refuses to run with thinking off.
      payload["generationConfig"] = ["thinkingConfig": ["thinkingLevel": thinkingLevel]]
    }
    return try JSONSerialization.data(withJSONObject: payload)
  }

  /// Google's own message out of an error body, which is the only actionable half of a failure.
  static func errorMessage(in data: Data) -> String? {
    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let error = json["error"] as? [String: Any],
      let message = error["message"] as? String,
      !message.isEmpty
    else { return nil }
    return message
  }

  // MARK: - Server-sent events

  /// One parsed SSE line's worth of meaning.
  enum StreamDelta: Equatable {
    case text(String)
    case failure(String)
  }

  /// Interprets a single line of the event stream. Pure, and deliberately total: the stream carries
  /// blank separators, comment lines and `data: [DONE]`, and every one of them has to be *ignored*
  /// rather than mistaken for an empty answer.
  static func deltaFromEventLine(_ line: String) -> StreamDelta? {
    guard line.hasPrefix("data:") else { return nil }
    let payload = line.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
    guard !payload.isEmpty, payload != "[DONE]", let data = payload.data(using: .utf8) else {
      return nil
    }
    guard let event = try? JSONDecoder().decode(GeminiReply.self, from: data) else { return nil }
    // An error can arrive mid-stream after a 200 — a quota trip on a later chunk, a safety stop.
    // Google's own message is the one the user can act on, so it is carried out verbatim.
    if let message = event.error?.message, !message.isEmpty { return .failure(message) }
    let text = event.candidates?.first?.content?.parts?.compactMap(\.text).joined() ?? ""
    return text.isEmpty ? nil : .text(text)
  }

  /// A stream that fails does so in its HTTP status, before any event arrives — a 429 or a bad key
  /// never becomes an event, so it has to be caught here or it reads as an empty answer.
  static func checkStreamStatus(_ response: URLResponse?) throws {
    guard let status = (response as? HTTPURLResponse)?.statusCode else { return }
    guard !(200..<300).contains(status) else { return }
    throw SuperModeError.http(status)
  }

  struct GeminiReply: Decodable {
    struct Candidate: Decodable {
      struct Content: Decodable {
        struct Part: Decodable { let text: String? }
        let parts: [Part]?
      }
      let content: Content?
    }
    struct APIError: Decodable { let message: String? }
    let candidates: [Candidate]?
    let error: APIError?
  }

  static func parseAnswer(data: Data, response: URLResponse?) throws -> String {
    let reply = try? JSONDecoder().decode(GeminiReply.self, from: data)
    // Google's own error message first: "API key not valid" is the one the user can act on, and the
    // bare 400 that carries it is not.
    if let message = reply?.error?.message, !message.isEmpty {
      throw SuperModeError.api(message)
    }
    if let status = (response as? HTTPURLResponse)?.statusCode, !(200..<300).contains(status) {
      throw SuperModeError.http(status)
    }
    let text =
      reply?.candidates?.first?.content?.parts?
      .compactMap(\.text).joined() ?? ""
    guard !text.isEmpty else { throw SuperModeError.empty }
    return text
  }

  static func failureText(_ error: Error) -> String {
    switch error {
    case SuperModeError.api(let message): return "Gemini: \(message)"
    case SuperModeError.http(let status): return "Gemini returned HTTP \(status)."
    case SuperModeError.empty: return "Gemini returned no answer."
    case SuperModeError.speedHintRejected: return "Gemini rejected the request twice."
    default: return "Could not reach Gemini: \(error.localizedDescription)"
    }
  }

  // MARK: - Elapsed

  /// `m:ss` under an hour, `h:mm:ss` past it. A mode that bills a user's own API key has to say how
  /// long it has been running without them having to do the subtraction.
  static func elapsedLabel(_ seconds: TimeInterval) -> String {
    let total = max(0, Int(seconds))
    let hours = total / 3600
    let minutes = (total % 3600) / 60
    let secs = total % 60
    return hours > 0
      ? String(format: "%d:%02d:%02d", hours, minutes, secs)
      : String(format: "%d:%02d", minutes, secs)
  }
}
