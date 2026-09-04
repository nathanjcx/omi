import Foundation

/// Decides whether a push-to-talk utterance is a *typing* command — "type <text>" —
/// and extracts the text to be typed.
///
/// The decision is now made once, on a complete utterance, which is what let
/// this file lose its third state. While text was typed as the user spoke the
/// parser also had to answer "might this still become a type command?" on every
/// fragment, because committing to "no" on the first two characters of a hold
/// rejected the feature outright (`"Ty"` arrives before `"Type hello"`) and
/// committing to "yes" on a bare `"type"` hijacked `"typescript generics,
/// explain them"`. Nothing asks that question any more: by the time anyone
/// calls this, the user has stopped talking and the whole sentence is here.
enum VoiceTypeCommandParser {

  enum Decision: Equatable {
    /// This turn types `payload` instead of asking Omi.
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
    guard !trimmed.isEmpty else { return .rejected }

    for wake in wakeWords.sorted(by: { $0.count > $1.count }) {
      guard trimmed.prefix(wake.count).lowercased() == wake else { continue }
      let rest = String(trimmed.dropFirst(wake.count))
      guard let first = rest.unicodeScalars.first, separators.contains(first) else {
        // "typescript", "typing", "typed" — the wake word is only a prefix of a
        // longer word, so this was never a command. A bare "type" with nothing
        // after it lands here too: there is no dictation in it.
        continue
      }
      let payload = String(
        rest.drop(while: { $0.unicodeScalars.allSatisfy(separators.contains) })
      )
      guard !payload.isEmpty else { continue }
      return .typing(payload: payload)
    }
    return .rejected
  }

  /// Applies a transcript correction to the dictated text only, never to the
  /// wake word.
  ///
  /// The on-screen keyword corrector spells names and jargon the way the screen
  /// spells them. Observed live: with a window title containing "typ", it
  /// rewrote the wake word itself — "Type, hello world" became "typ, hello
  /// world" — and the parser then rejected the turn. The realtime model, hearing
  /// "type …", spawned an agent to do the typing. So the wake word is split off
  /// before correction and put back verbatim afterwards; a transcript that is
  /// not a typing command is returned untouched.
  static func correctingPayload(_ transcript: String, using correct: (String) -> String) -> String {
    guard case .typing = decide(transcript) else { return transcript }
    let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
    for wake in wakeWords.sorted(by: { $0.count > $1.count })
    where trimmed.prefix(wake.count).lowercased() == wake {
      let rest = trimmed.dropFirst(wake.count)
      let payloadStart = rest.firstIndex(where: { !$0.unicodeScalars.allSatisfy(separators.contains) })
      guard let payloadStart else { return transcript }
      let prefix = String(trimmed[..<payloadStart])
      let payload = String(trimmed[payloadStart...])
      return prefix + correct(payload)
    }
    return transcript
  }
}
