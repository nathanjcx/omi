import Foundation

/// Decides whether a push-to-talk utterance is a *typing* command — "type <text>" —
/// and extracts the text to be typed.
///
/// The parser runs on partial transcripts too (a mid-hold probe hears the first
/// seconds of the turn), so it is deliberately tri-state. Committing to "not a
/// type command" on a fragment would reject the feature outright (`"Ty"`
/// arrives before `"Type hello"`), and committing to "is a type command" on a
/// bare `"type"` would hijack a turn that turns out to be `"typescript
/// generics, explain them"`. Only a wake word followed by a word boundary, which
/// no longer wake word could still absorb, is decidable.
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

  /// Spellings a recognizer gives the spoken word "type" when it does not hear
  /// it as "type". Consulted only once the turn is already known to dictate.
  private static let wakeWordMishearings = ["typed", "types", "typing", "tie", "tight", "tape", "typo", "tap"]

  /// The text to type from a transcript of a turn that is already known to be
  /// a dictation.
  ///
  /// The closing transcript comes from a stronger recognizer than the probe
  /// that claimed the turn, and it may render the wake word another way. When
  /// the strict parse fails, a leading word that reads as a mishearing of
  /// "type" is dropped; failing that, the whole transcript is the dictation.
  /// One stray word at the front is recoverable; a dictation that never
  /// arrives is not.
  static func payloadAssumingDictation(_ transcript: String) -> String {
    if case .typing(let payload) = decide(transcript) { return payload }
    let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
    let separatorClass = "[\\s,:;.\\-–—]*"
    let alternatives = (wakeWords + wakeWordMishearings).map(NSRegularExpression.escapedPattern(for:))
    let pattern = "^(?i)(?:" + alternatives.joined(separator: "|") + ")\\b" + separatorClass
    if let range = trimmed.range(of: pattern, options: .regularExpression) {
      return capitalizingFirstWord(String(trimmed[range.upperBound...]))
    }
    return capitalizingFirstWord(trimmed)
  }

  /// Applies a transcript correction to the dictated text only, never to the
  /// wake word.
  ///
  /// The on-screen keyword corrector is run on every transcript so names and
  /// jargon visible on screen are spelled the way the screen spells them.
  /// Observed live: with a window title containing "typ", it rewrote the wake
  /// word itself — "Type, hello world" became "typ, hello world" — and the
  /// parser then rejected the turn, so the realtime model, hearing "type …",
  /// spawned an agent to do the typing. So the wake word is split off before
  /// correction and put back verbatim afterwards; a transcript that is not a
  /// typing command is returned untouched.
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

  /// Dictation starts a sentence. The recognizer lowercases the first word
  /// because it heard it mid-utterance, right after the wake word, so it is
  /// restored here.
  static func capitalizingFirstWord(_ payload: String) -> String {
    guard let first = payload.first, first.isLowercase else { return payload }
    return payload.prefix(1).uppercased() + payload.dropFirst()
  }
}
