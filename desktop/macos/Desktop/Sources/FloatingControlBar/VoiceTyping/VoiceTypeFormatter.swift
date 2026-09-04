import Foundation

/// Turns a finished transcript into the text worth pasting.
///
/// Only possible once the whole utterance is in hand. Typing as the user spoke,
/// every one of these passes had to be re-run on a growing string and produce
/// the same answer each time or the screen churned; several of them cannot be,
/// because a sentence boundary is not visible until the sentence ends.
///
/// The rule this file follows is that it may **delete a filler, move a space,
/// or raise a letter to a capital, and nothing else**. It never lowercases (an
/// acronym or a surname would lose), never inserts or removes punctuation the
/// speaker did not say, and never rewrites a word. A formatter that improves
/// nine sentences and corrupts the tenth is a worse accuracy bug than the one
/// it set out to fix, and the user cannot tell which one they got.
///
/// Spoken punctuation commands ("period", "new line") are deliberately absent.
/// They cannot be told apart from dictation deterministically — "the period of
/// the wave" is a sentence someone will say — and guessing wrong deletes a word
/// the user did say.
enum VoiceTypeFormatter {

  /// Sounds people make between words. Matched only as whole tokens, so
  /// "umbrella" and "uhtred" are untouched.
  ///
  /// Kept deliberately short. "ah", "oh", and "er" all carry meaning in
  /// ordinary sentences ("ah, I see"), so they stay.
  static let fillers: Set<String> = ["um", "umm", "ummm", "uh", "uhh", "uhhh", "uhm", "erm"]

  private static let sentenceEnders: Set<Character> = [".", "!", "?"]
  /// Punctuation a recognizer sometimes emits with a space in front of it.
  private static let hugsPreviousWord: Set<Character> = [",", ".", "!", "?", ";", ":", "%"]

  static func format(_ transcript: String) -> String {
    // Line structure survives: a recognizer rarely emits newlines, but when one
    // does it is a paragraph the speaker asked for, and flattening it would be
    // the formatter changing the text rather than tidying it.
    let lines = transcript.split(separator: "\n", omittingEmptySubsequences: false)
    let formatted = lines.map { capitalizingSentences(tighteningPunctuation(droppingFillers(String($0)))) }
    return formatted.joined(separator: "\n").trimmingCharacters(in: .whitespaces)
  }

  /// Drops filler tokens, taking any punctuation the recognizer attached to
  /// them with it — "So, um, the thing" has to lose the whole "um," or the
  /// tidy-up leaves a doubled comma behind.
  static func droppingFillers(_ text: String) -> String {
    let tokens = text.split(separator: " ", omittingEmptySubsequences: true)
    let kept = tokens.filter { token in
      let bare = token.lowercased().trimmingCharacters(in: .punctuationCharacters)
      return !fillers.contains(bare)
    }
    return kept.joined(separator: " ")
  }

  /// Pulls punctuation back onto the word it belongs to and collapses runs of
  /// spaces. Recognizers emit " ," and "word ." often enough to be noticeable,
  /// and it is the tell that text came out of a machine.
  static func tighteningPunctuation(_ text: String) -> String {
    var result = ""
    result.reserveCapacity(text.count)
    for character in text {
      if character == " " {
        // One space, never two, and never one at the start.
        if !result.isEmpty, result.last != " " { result.append(character) }
        continue
      }
      if hugsPreviousWord.contains(character) {
        while result.last == " " { result.removeLast() }
        result.append(character)
        continue
      }
      result.append(character)
    }
    return result
  }

  /// Raises the first letter of the text and of every following sentence.
  ///
  /// Upward only. A recognizer that returned "iPhone" or "API" mid-sentence got
  /// it right, and a pass that normalized case would be undoing the accuracy
  /// this whole change is for.
  ///
  /// Works a token at a time rather than a character at a time, because whether
  /// a period ends a sentence is a property of the word it is attached to, not
  /// of the period. Reading characters, "Use e.g. this one" became "Use e.g.
  /// This one".
  static func capitalizingSentences(_ text: String) -> String {
    let tokens = text.split(separator: " ", omittingEmptySubsequences: false)
    var awaitingSentenceStart = true
    var result: [String] = []
    result.reserveCapacity(tokens.count)
    for token in tokens {
      var word = String(token)
      // Punctuation on its own ("—") is not where a sentence starts, so it
      // neither takes the capital nor consumes the pending one.
      let carriesContent = word.contains(where: { $0.isLetter || $0.isNumber })
      if awaitingSentenceStart, carriesContent { word = raisingFirstLetter(word) }
      if carriesContent { awaitingSentenceStart = false }
      if endsSentence(word) { awaitingSentenceStart = true }
      result.append(word)
    }
    return result.joined(separator: " ")
  }

  private static func raisingFirstLetter(_ token: String) -> String {
    guard let letter = token.firstIndex(where: { $0.isLetter }) else { return token }
    // "3rd" opens with a digit, and its first *letter* is in the middle of the
    // word — raising it would produce "3Rd".
    guard !token[..<letter].contains(where: { $0.isNumber }) else { return token }
    return token[..<letter] + String(token[letter]).uppercased() + token[token.index(after: letter)...]
  }

  /// Whether `token` closes a sentence, as opposed to merely ending in a dot.
  private static func endsSentence(_ token: String) -> Bool {
    guard let last = token.last, sentenceEnders.contains(last) else { return false }
    // "!" and "?" are unambiguous; only the period is overloaded.
    guard last == "." else { return true }
    let body = token.dropLast()
    // "e.g.", "i.e.", "U.S." — a token carrying interior periods is an
    // abbreviation. A lone "." closes nothing either.
    guard !body.contains("."), body.contains(where: { $0.isLetter || $0.isNumber }) else {
      return false
    }
    return true
  }
}
