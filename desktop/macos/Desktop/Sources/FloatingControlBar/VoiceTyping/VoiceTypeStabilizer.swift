import Foundation

/// Holds back the part of a live transcript that is still moving.
///
/// Each probe re-decodes the whole turn buffer from scratch, so the tail of one
/// decode is a half-heard word that the next decode rewrites — and a word that
/// is typed and then rewritten reads as flicker, which is exactly what "real
/// time but glitchy" looks like. Only text that two consecutive decodes agree
/// on, cut back to a whole word, is handed on to be typed; the moving edge waits
/// one probe. Costs a word of latency, removes nearly all of the churn.
struct VoiceTypeStabilizer {

  private var previous = ""

  /// The prefix of `candidate` that is safe to type now.
  mutating func stabilized(_ candidate: String) -> String {
    let agreed = Self.commonPrefix(previous, candidate)
    previous = candidate
    return Self.wholeWordsOnly(agreed: agreed, candidate: candidate)
  }

  /// The turn is over: nothing is still moving, so the whole transcript stands.
  mutating func settle(_ final: String) -> String {
    previous = final
    return final
  }

  mutating func reset() {
    previous = ""
  }

  private static func commonPrefix(_ lhs: String, _ rhs: String) -> String {
    var result = ""
    var left = lhs.startIndex
    var right = rhs.startIndex
    while left < lhs.endIndex, right < rhs.endIndex, lhs[left] == rhs[right] {
      result.append(lhs[left])
      left = lhs.index(after: left)
      right = rhs.index(after: right)
    }
    return result
  }

  /// Trims the agreed prefix only when it stops *inside* a word the newer decode
  /// is still spelling ("Type hell" → "Type hello"). When the newer decode
  /// continues with a space, the agreed words are whole and are released
  /// immediately — waiting another probe there costs a word of latency and buys
  /// nothing. An unchanged decode releases in full, so a pause catches up.
  private static func wholeWordsOnly(agreed: String, candidate: String) -> String {
    guard let lastAgreed = agreed.last, !lastAgreed.isWhitespace else { return agreed }
    let boundary = candidate.index(candidate.startIndex, offsetBy: agreed.count)
    guard boundary < candidate.endIndex, !candidate[boundary].isWhitespace else { return agreed }
    return throughLastWordBoundary(agreed)
  }

  /// Drops a trailing partial word, keeping the separator so the next word
  /// appends cleanly instead of re-typing the space.
  private static func throughLastWordBoundary(_ text: String) -> String {
    guard let lastSeparator = text.lastIndex(where: { $0.isWhitespace }) else { return "" }
    return String(text[...lastSeparator])
  }
}
