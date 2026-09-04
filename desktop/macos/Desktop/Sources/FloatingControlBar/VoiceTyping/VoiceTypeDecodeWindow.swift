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
///
/// The window is also the turn's *timeline*. Every byte of mic audio since
/// key-down passes through it, and `consumedBytes` counts how much has been
/// dropped, so a position in the turn (a streaming recognizer's utterance
/// `start`/`end`) maps onto the pending audio. That is what lets the backend
/// stream commit text by time (`adoptStreamFinal`) while the on-device decoder
/// keeps typing the moving edge from the same buffer: two recognizers, one
/// timeline, and no region ever committed twice.
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
  /// Bytes of turn audio dropped from the front so far. `pendingAudio` begins
  /// at this offset in the turn, so turn-relative positions map onto it.
  private(set) var consumedBytes = 0

  var hasCommitted: Bool { !committedText.isEmpty }

  /// Turn-relative byte offset just past the last audio appended.
  var appendedBytes: Int { consumedBytes + pendingAudio.count }

  mutating func append(_ chunk: Data) {
    pendingAudio.append(chunk)
  }

  enum StreamFinalOutcome: Equatable {
    /// The utterance's text is now the committed prefix and its audio is gone.
    case adopted
    /// The utterance began inside audio already committed (by an earlier local
    /// commit or an earlier final). Its text is dropped rather than typed twice.
    case alreadyCommitted
    /// Nothing to commit: empty text, or an utterance that ends before the
    /// consumed edge.
    case ignored
    /// Speech lies between the consumed edge and the utterance's start that no
    /// recognizer has committed. Adopting would drop that audio with its words
    /// never typed, so the final is refused and the local decode keeps the
    /// whole stretch.
    case uncommittedSpeechBefore
  }

  /// Commits a streaming recognizer's finished utterance by its position in the
  /// turn, replacing the local decode of that same audio.
  ///
  /// The backend stream (`velma-2` and its fallbacks) is the stronger model but
  /// only speaks at pauses, and each message is one utterance — a delta, never
  /// the whole transcript. So each final is folded in here: it becomes the next
  /// committed stretch and the audio it covers is dropped, exactly as a local
  /// commit would, so the on-device decoder carries on from where the stream
  /// left off. Replacing the whole transcript with each message was the bug
  /// that froze dictation after the first pause: the second utterance no
  /// longer opened with the wake word and nothing downstream would type it.
  ///
  /// A final that starts inside already-committed audio is refused. Commits
  /// are irreversible on both sides, so the first recognizer to freeze a region
  /// owns it; the other's text for that region is discarded, never appended.
  ///
  /// A final that starts *after* the consumed edge is adopted only if the gap
  /// is silent. Observed live: a forced local cut at 20 s left the stream's
  /// in-flight utterance straddling the edge (refused), and the next final,
  /// starting 10 s later, was adopted — the two sentences in between had only
  /// ever been the moving edge, and their audio went with the commit. The
  /// local decode owns any gap that holds speech; the stream resumes at the
  /// next pause it reaches first.
  ///
  /// The seam is moved from `endByte` to the next quiet window (within
  /// `VoiceTypeAudioTrim.quietBoundary`'s lookahead) when the audio there is
  /// still loud, so the next window never opens on the tail of a word the
  /// stream already spelled. Observed live as doubled endings ("two NGs").
  ///
  /// - Parameters:
  ///   - text: the utterance.
  ///   - startByte: turn-relative offset of the utterance's first sample.
  ///   - endByte: turn-relative offset just past its last sample.
  @discardableResult
  mutating func adoptStreamFinal(text: String, startByte: Int, endByte: Int) -> StreamFinalOutcome {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return .ignored }
    guard startByte >= consumedBytes else { return .alreadyCommitted }
    guard endByte > consumedBytes else { return .ignored }
    if uncommittedSpeech(before: startByte) != nil {
      return .uncommittedSpeechBefore
    }
    var drop = min(endByte - consumedBytes, pendingAudio.count)
    if let quiet = VoiceTypeAudioTrim.quietBoundary(in: pendingAudio, from: drop) {
      drop = max(drop, min(quiet, pendingAudio.count))
    }
    // Rebuilt, not sliced: `removeFirst` / `dropFirst` leave a `Data` whose
    // indices start at `drop`, and every consumer here indexes from zero
    // (`subdata(in:)` in the trimmer crashed the app on the first probe after
    // a stream commit).
    pendingAudio = Data(pendingAudio.dropFirst(drop))
    consumedBytes += drop
    committedText = transcript(tail: trimmed)
    return .adopted
  }

  /// The whole utterance: everything committed, plus this window's decode.
  ///
  /// Every window is a fresh utterance to the recognizer, so it capitalizes
  /// the first word — mid-sentence, at a seam ("However, A few users"). When
  /// the committed text has not ended a sentence, a capitalized first word is
  /// lowered unless it is the pronoun "I" or an all-caps token. A proper noun
  /// at a seam loses its capital; a common word at a seam is far more common.
  func transcript(tail: String) -> String {
    let trimmedTail = tail.trimmingCharacters(in: .whitespaces)
    guard !committedText.isEmpty else { return trimmedTail }
    guard !trimmedTail.isEmpty else { return committedText }
    return committedText + " " + Self.continuingSentence(after: committedText, tail: trimmedTail)
  }

  private static let sentenceEnders: Set<Character> = [".", "!", "?", "\n"]

  static func continuingSentence(after committed: String, tail: String) -> String {
    guard let last = committed.last, !sentenceEnders.contains(last),
      let first = tail.first, first.isUppercase
    else { return tail }
    let word = tail.prefix(while: { $0.isLetter || $0 == "'" })
    let isPronounI = word == "I" || word.hasPrefix("I'")
    let isAllCaps = word.count > 1 && word.allSatisfy(\.isUppercase)
    guard !isPronounI, !isAllCaps else { return tail }
    return first.lowercased() + tail.dropFirst()
  }

  /// The audio between the consumed edge and `startByte`, when it holds speech
  /// no recognizer has committed — what `adoptStreamFinal` would refuse over.
  /// The caller decodes it on-device and commits both texts together through
  /// `adoptStreamFinal(text:startByte: consumedBytes, …)`, so a speaker who
  /// never pauses long enough for a local commit still gets the stream's text
  /// for the stretches it finished.
  func uncommittedSpeech(before startByte: Int) -> Data? {
    let gap = min(startByte - consumedBytes, pendingAudio.count)
    guard gap > 0 else { return nil }
    let audio = VoiceTypeAudioTrim.trimmingLeadingSilence(Data(pendingAudio.prefix(gap)))
    // Below half a second of voice there is no word to recover, only a
    // syllable's tail or a breath, and the decoder answers those with an
    // invented phrase ("Thank you." — observed live, twice in one hold).
    return VoiceTypeAudioTrim.speechBytes(in: audio) < Self.minimumDecodableSpeechBytes ? nil : audio
  }

  /// The least voiced audio worth decoding on its own: 0.5 s at 16 kHz s16le.
  static let minimumDecodableSpeechBytes = 16_000

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
    consumedBytes += pendingAudio.count
    pendingAudio = Data()
    return true
  }

  mutating func reset() {
    committedText = ""
    pendingAudio = Data()
    consumedBytes = 0
  }
}
