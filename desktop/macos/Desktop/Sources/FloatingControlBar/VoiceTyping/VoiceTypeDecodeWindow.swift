import Foundation

/// Holds the only audio voice typing still needs to look at, and commits text
/// once it has been typed.
///
/// Two things forced this. Re-decoding the whole turn on every probe costs more
/// the longer the hold, and the shared PTT buffer stops growing at its own cap
/// (`maxBatchAudioBytes`) — past which the tail handed to the recognizer never
/// changed again and typing simply stopped mid-sentence.
///
/// So typing keeps its own short buffer instead. Once a stretch has been typed
/// it is *committed* — its text becomes an immutable prefix and its audio is
/// dropped. Later probes decode only what has been said since. Cost per probe
/// is bounded by the window, memory is bounded by the window, and a hold can
/// run as long as the user likes.
///
/// Committing prefers a pause. Cutting mid-word would hand the next window a
/// fragment and spell it wrong, so the window grows past its target until the
/// speaker draws breath, and is only forced at `maxBytes`.
struct VoiceTypeDecodeWindow {

  /// Commit at the first pause after this much audio. Small on purpose: once
  /// text is typed it should stop being reconsidered. At ~100× realtime this
  /// keeps a probe well under 100 ms.
  static let targetBytes = 6 * 16_000 * 2
  /// Hard limit, for a speaker who never pauses. Past this the window commits
  /// wherever it is.
  static let maxBytes = 20 * 16_000 * 2

  /// Text already typed and no longer revisable.
  private(set) var committedText = ""
  /// Audio spoken since the last commit — the only audio still decoded.
  private(set) var pendingAudio = Data()

  var hasCommitted: Bool { !committedText.isEmpty }

  mutating func append(_ chunk: Data) {
    pendingAudio.append(chunk)
  }

  /// The whole utterance: everything committed, plus this window's decode.
  func transcript(tail: String) -> String {
    let trimmedTail = tail.trimmingCharacters(in: .whitespaces)
    guard !committedText.isEmpty else { return trimmedTail }
    guard !trimmedTail.isEmpty else { return committedText }
    return committedText + " " + trimmedTail
  }

  /// Commits the window if it has grown enough and this is a good place to cut.
  ///
  /// - Parameters:
  ///   - tail: the decode of the pending audio.
  ///   - endsQuiet: whether the pending audio ends in near-silence, i.e. the
  ///     speaker has paused and no word is being cut in half.
  /// - Returns: whether the window committed.
  @discardableResult
  mutating func commitIfReady(tail: String, endsQuiet: Bool) -> Bool {
    let bytes = pendingAudio.count
    guard bytes >= Self.targetBytes else { return false }
    guard endsQuiet || bytes >= Self.maxBytes else { return false }
    let trimmedTail = tail.trimmingCharacters(in: .whitespacesAndNewlines)
    // Committing silence would strand the rest of the turn behind a prefix that
    // can never be revised, so a window with nothing in it just keeps growing.
    guard !trimmedTail.isEmpty else { return false }
    committedText = transcript(tail: trimmedTail)
    pendingAudio = Data()
    return true
  }

  mutating func reset() {
    committedText = ""
    pendingAudio = Data()
  }
}
