import Foundation

/// One dictation's audio, held whole until the key comes up.
///
/// This is the entire reason paste-on-release is more accurate than typing as
/// the user speaks. A recognizer decoding six seconds of a sentence has no idea
/// what the next six seconds contain, so it guesses at the words on the
/// boundary and revises them a moment later; the streaming design that came
/// before this had to freeze those guesses to make progress, and a frozen guess
/// is a permanently misspelled word in the user's document. Holding the audio
/// costs 32 KB per second and buys the recognizer the whole sentence — every
/// word decoded with the context that follows it, and nothing typed that has to
/// be taken back.
///
/// There is no commit, no seam, and no timeline here, because nothing is
/// delivered until the utterance is complete.
struct VoiceTypeUtterance {

  /// 4.5 minutes at 16 kHz s16le, matching `PushToTalkManager.maxBatchAudioBytes`:
  /// the backend batch endpoint answers 413 past roughly five minutes, so the
  /// cap has to bite before the request would be refused outright.
  static let defaultMaxBytes = Int(4.5 * 60) * 16_000 * 2

  let maxBytes: Int

  /// Every byte of mic audio since key-down, up to `maxBytes`.
  private(set) var audio = Data()
  /// Set once the cap has dropped audio. The dictation still delivers what it
  /// has — a truncated sentence beats a discarded one — but the caller reports
  /// it, because the user's last words are missing and only they can tell.
  private(set) var didTruncate = false

  init(maxBytes: Int = VoiceTypeUtterance.defaultMaxBytes) {
    self.maxBytes = maxBytes
  }

  var seconds: Double { Double(audio.count / 2) / 16_000 }

  mutating func append(_ chunk: Data) {
    guard audio.count < maxBytes else {
      didTruncate = true
      return
    }
    let room = maxBytes - audio.count
    if chunk.count <= room {
      audio.append(chunk)
    } else {
      audio.append(chunk.prefix(room))
      didTruncate = true
    }
  }

  /// The audio to hand a recognizer, or nil when the turn holds no speech.
  ///
  /// Silence is trimmed from both ends and the remainder has to carry at least
  /// `VoiceTypeAudioTrim.minimumDecodableSpeechBytes` of voice. Both halves of
  /// that matter: a hold begins at key-down and ends at key-up, so a turn is
  /// bracketed by room tone that a recognizer answers with invented words
  /// rather than with nothing.
  func decodableAudio() -> Data? {
    let trimmed = VoiceTypeAudioTrim.trimmingSilence(audio)
    guard VoiceTypeAudioTrim.speechBytes(in: trimmed) >= VoiceTypeAudioTrim.minimumDecodableSpeechBytes
    else { return nil }
    return trimmed
  }

  mutating func reset() {
    audio = Data()
    didTruncate = false
  }
}
