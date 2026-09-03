import AVFoundation
import Foundation

/// **Super Mode speaks in Omi's voice, not in a second one.**
///
/// `RealtimeHubVoicePolicy` is this app's single authority on who Omi sounds like: Charon on Gemini,
/// cedar on OpenAI, deliberately matched so that swapping providers changes the engine and not the
/// person. Super Mode's first spoken answers went out through `FloatingBarVoicePlaybackService`,
/// which synthesizes text with OpenAI TTS in whichever voice the user picked in Settings — Shimmer
/// by default. So holding the mic in Super Mode answered in a different voice than holding it a
/// moment earlier did, which reads as a different assistant rather than a different mode.
///
/// The mismatch is structural, not a setting: an ordinary push-to-talk reply is *generated* as
/// speech by Gemini Live, while a Super Mode reply is text that has to be spoken afterwards. The fix
/// is to synthesize it with Gemini's own TTS and name the same voice the hub is pinned to, read from
/// the same policy — so if that policy ever changes, this follows without being edited.
///
/// It runs on the user's key, like everything else in this mode, and returns the same 24 kHz mono
/// PCM the realtime lane already plays, so it feeds `StreamingPCMPlayer` directly with no conversion.
@MainActor
final class SuperModeVoice {
  static let shared = SuperModeVoice()

  /// Flash rather than pro: this is the last hop before the user hears anything, so latency here is
  /// the tail of every spoken answer.
  static let model = "gemini-3.1-flash-tts-preview"

  /// Never a literal. Read from the one authority for Omi's voice, so Super Mode cannot drift away
  /// from the hub the way it did the first time.
  static var voiceName: String { RealtimeHubVoicePolicy.voiceName(for: .gemini) }

  /// A chunk is synthesized once the text reaches a sentence end, so speech starts on sentence one
  /// instead of after the whole answer — the same reason the answer itself streams. This cap forces
  /// a break in prose that never punctuates, so a run-on paragraph cannot hold the audio forever.
  static let maxChunkCharacters = 220

  private let player = StreamingPCMPlayer(sampleRate: 24000)
  private var pending = ""
  /// Serializes synthesis so chunks are enqueued in the order they were spoken in. Without it two
  /// concurrent requests race and the second sentence can reach the speaker first.
  private var queue: Task<Void, Never>?

  private init() {}

  /// Adds newly streamed text, speaking whatever complete sentences it now contains.
  func speak(_ fragment: String) {
    pending += fragment
    while let chunk = Self.nextChunk(from: &pending, isFinal: false) {
      enqueue(chunk)
    }
  }

  /// Speaks whatever is left once the answer is complete, including a trailing fragment that never
  /// got its full stop.
  func finish() {
    while let chunk = Self.nextChunk(from: &pending, isFinal: true) {
      enqueue(chunk)
    }
  }

  /// Barge-in and turn changes. Cancels queued synthesis and drops audio already scheduled.
  func stop() {
    queue?.cancel()
    queue = nil
    pending = ""
    player.stop()
  }

  private func enqueue(_ text: String) {
    let previous = queue
    queue = Task { @MainActor [weak self] in
      // Await the chunk before this one so playback order matches reading order, and inherit its
      // cancellation: a stop mid-answer must not let a later sentence still arrive.
      _ = await previous?.value
      guard !Task.isCancelled, let self else { return }
      guard let pcm = await Self.synthesize(text, key: SuperModeController.shared.apiKey) else {
        return
      }
      guard !Task.isCancelled else { return }
      _ = self.player.enqueue(pcm)
    }
  }

  // MARK: - Wire format (pure, so the voice contract is testable without a network)

  static var endpoint: URL {
    URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent")!
  }

  static func requestBody(text: String) throws -> Data {
    try JSONSerialization.data(withJSONObject: [
      "contents": [["parts": [["text": text]]]],
      "generationConfig": [
        "responseModalities": ["AUDIO"],
        "speechConfig": ["voiceConfig": ["prebuiltVoiceConfig": ["voiceName": voiceName]]],
      ],
    ])
  }

  /// Pulls the raw PCM out of the reply. The audio arrives as base64 `inlineData` at
  /// `audio/l16; rate=24000` — signed 16-bit little-endian mono, which is exactly what
  /// `StreamingPCMPlayer` is built for, so there is no decode step and no resample.
  static func pcm(fromResponse data: Data) -> Data? {
    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let candidates = json["candidates"] as? [[String: Any]],
      let content = candidates.first?["content"] as? [String: Any],
      let parts = content["parts"] as? [[String: Any]],
      // Both spellings appear across API versions; accepting one only is a silent no-audio bug.
      let inline = parts.compactMap({ ($0["inlineData"] ?? $0["inline_data"]) as? [String: Any] })
        .first,
      let base64 = inline["data"] as? String
    else { return nil }
    return Data(base64Encoded: base64)
  }

  private static func synthesize(_ text: String, key: String) async -> Data? {
    let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !key.isEmpty else { return nil }
    var request = URLRequest(url: endpoint)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
    request.timeoutInterval = 60
    do {
      request.httpBody = try requestBody(text: text)
      let (data, response) = try await URLSession.shared.data(for: request)
      if let status = (response as? HTTPURLResponse)?.statusCode, !(200..<300).contains(status) {
        // Silence is the failure mode here, so the reason has to reach the log — the answer is
        // already on screen either way.
        log("SuperModeVoice: speech synthesis returned HTTP \(status)")
        return nil
      }
      return pcm(fromResponse: data)
    } catch {
      log("SuperModeVoice: speech synthesis failed (\(error.localizedDescription))")
      return nil
    }
  }

  // MARK: - Chunking

  /// Takes the next speakable chunk off the front of `buffer`, or nil if none is ready.
  ///
  /// Pure and `inout` so the caller keeps no second copy of the boundary rule — a chunker whose
  /// "what was consumed" disagrees with "what was spoken" repeats or drops a sentence.
  static func nextChunk(from buffer: inout String, isFinal: Bool) -> String? {
    let trimmed = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      buffer = ""
      return nil
    }
    if let end = sentenceEnd(in: buffer) {
      let chunk = String(buffer[buffer.startIndex..<end]).trimmingCharacters(
        in: .whitespacesAndNewlines)
      buffer = String(buffer[end...])
      return chunk.isEmpty ? nextChunk(from: &buffer, isFinal: isFinal) : chunk
    }
    // Prose that never punctuates would otherwise hold every later sentence behind it.
    if buffer.count >= maxChunkCharacters {
      let end = buffer.index(buffer.startIndex, offsetBy: maxChunkCharacters)
      let chunk = String(buffer[buffer.startIndex..<end])
      buffer = String(buffer[end...])
      return chunk
    }
    guard isFinal else { return nil }
    buffer = ""
    return trimmed
  }

  /// Index just past a sentence-ending mark that is actually the end of a sentence — a full stop
  /// followed by whitespace, rather than the one inside `1.5` or `gemini-3.1-pro`.
  private static func sentenceEnd(in text: String) -> String.Index? {
    var index = text.startIndex
    while index < text.endIndex {
      let character = text[index]
      let next = text.index(after: index)
      if character == "\n" { return next }
      if character == "." || character == "!" || character == "?" {
        if next == text.endIndex { return nil }
        if text[next].isWhitespace { return next }
      }
      index = next
    }
    return nil
  }
}
