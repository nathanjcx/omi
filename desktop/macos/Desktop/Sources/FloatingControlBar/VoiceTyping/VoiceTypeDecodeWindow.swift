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

  /// Overridable so the sizing can be swept in tests rather than guessed at.
  let targetBytes: Int
  let maxBytes: Int

  init(
    targetBytes: Int = VoiceTypeDecodeWindow.targetBytes,
    maxBytes: Int = VoiceTypeDecodeWindow.maxBytes
  ) {
    self.targetBytes = targetBytes
    self.maxBytes = maxBytes
  }

  /// Text already typed and no longer revisable.
  private(set) var committedText = ""
  /// Audio spoken since the last commit — the only audio still decoded.
  private(set) var pendingAudio = Data()

  var hasCommitted: Bool { !committedText.isEmpty }

  mutating func append(_ chunk: Data) {
    pendingAudio.append(chunk)
  }

  /// Takes over from another recognizer, treating its transcript as already
  /// typed and starting a fresh window.
  ///
  /// Used when the backend stream dies mid-dictation: the words it streamed are
  /// on screen, so they are the committed prefix, and the local model resumes
  /// from the audio that follows rather than leaving a hole in the sentence.
  mutating func adopt(committedText text: String) {
    committedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
    pendingAudio = Data()
  }

  /// The whole utterance: everything committed, plus this window's decode.
  func transcript(tail: String) -> String {
    let trimmedTail = tail.trimmingCharacters(in: .whitespaces)
    guard !committedText.isEmpty else { return trimmedTail }
    guard !trimmedTail.isEmpty else { return committedText }
    return committedText + " " + trimmedTail
  }

  /// Commits the window if it has grown enough and the text is safe to freeze.
  ///
  /// A commit is irreversible: its text becomes an immutable prefix, so text
  /// that is still moving must never enter one. The recognizer's newest word is
  /// exactly that — the stabilizer holds it back from being typed for the same
  /// reason — and committing it froze a half-heard word permanently into the
  /// user's document ("token19" typed as "token1").
  ///
  /// So a commit needs a *settled* decode: the speaker paused and two probes
  /// agreed on what they heard. Then the whole window is frozen and all of its
  /// audio is dropped — text and audio stay exactly aligned, which is what
  /// keeps words from being duplicated or dropped at the seam.
  ///
  /// A speaker who never pauses is still cut at `maxBytes`, and that cut can
  /// clip the word being spoken across it. Withholding that word instead was
  /// tried and is worse: without word timestamps there is no way to keep
  /// exactly its audio, and keeping too much re-emitted the previous word
  /// ("word47 word47"). One occasionally clipped word on a speaker who has not
  /// drawn breath in twenty seconds beats duplicated words for everyone.
  ///
  /// - Parameters:
  ///   - tail: the decode of the pending audio.
  ///   - endsQuiet: whether the pending audio ends in near-silence.
  ///   - tailIsStable: whether this decode matches the previous probe's, i.e.
  ///     the recognizer has stopped revising it.
  /// - Returns: whether the window committed.
  @discardableResult
  mutating func commitIfReady(tail: String, endsQuiet: Bool, tailIsStable: Bool) -> Bool {
    let bytes = pendingAudio.count
    guard bytes >= targetBytes else { return false }
    let settled = endsQuiet && tailIsStable
    guard settled || bytes >= maxBytes else { return false }
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
