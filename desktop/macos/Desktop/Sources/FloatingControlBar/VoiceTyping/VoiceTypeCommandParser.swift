import Foundation

/// Decides whether a push-to-talk utterance is a *typing* command — "type <text>" —
/// and extracts the text to be typed.
///
/// The parser runs on a transcript that is still growing, so it is deliberately
/// tri-state. Committing to "not a type command" on the first fragment would
/// reject the feature outright (`"Ty"` arrives before `"Type hello"`), and
/// committing to "is a type command" on a bare `"type"` would hijack a turn that
/// turns out to be `"typescript generics, explain them"`. Only a wake word
/// followed by a word boundary, which no longer wake word could still absorb,
/// is decidable.
enum VoiceTypeCommandParser {

  enum Decision: Equatable {
    /// The transcript is still a viable prefix of a type command. Type nothing
    /// yet, but do not route the turn to chat either.
    case undecided
    /// This turn types `payload` instead of asking Omi. `payload` may be empty
    /// while the user has said only the wake word.
    case typing(payload: String)
    /// Not a type command. The turn routes to chat as usual.
    case rejected
  }

  /// Spoken openings that start a typing turn. `"type"` is the documented one;
  /// the others are what ASR reliably returns for the same intent, and they are
  /// matched longest-first so "type out hello" dictates "hello", not "out hello".
  static let wakeWords = ["type out", "type this", "type"]

  /// Punctuation ASR attaches to the wake word ("Type, hello") or that opens the
  /// dictated text. Stripped from the front of the payload, never from its body.
  private static let separators = CharacterSet(charactersIn: " \t\n,:;.-–—")

  static func decide(_ transcript: String) -> Decision {
    let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return .undecided }
    let lowered = trimmed.lowercased()

    // A transcript that is still a prefix of any wake word decides nothing yet.
    // This covers both the first fragments ("ty") and the ambiguous overlap
    // between wake words ("type o" may still become "type out"), so a longer
    // wake word is never stolen by a shorter one mid-stream.
    if wakeWords.contains(where: { $0.hasPrefix(lowered) }) {
      return .undecided
    }

    for wake in wakeWords.sorted(by: { $0.count > $1.count }) {
      guard trimmed.prefix(wake.count).lowercased() == wake else { continue }
      let rest = String(trimmed.dropFirst(wake.count))
      guard let first = rest.unicodeScalars.first, separators.contains(first) else {
        // "typescript", "typing", "typed" — the wake word is only a prefix of a
        // longer word, so this was never a command.
        continue
      }
      let payload = String(
        rest.drop(while: { $0.unicodeScalars.allSatisfy(separators.contains) })
      )
      return .typing(payload: capitalizingFirstWord(payload))
    }
    return .rejected
  }

  /// Dictation starts a sentence. The recognizer lowercases the first word
  /// because it heard it mid-utterance, right after the wake word, so it is
  /// restored here — and restored on every revision, so the planner's diff never
  /// churns over the capital itself.
  private static func capitalizingFirstWord(_ payload: String) -> String {
    guard let first = payload.first, first.isLowercase else { return payload }
    return payload.prefix(1).uppercased() + payload.dropFirst()
  }
}
