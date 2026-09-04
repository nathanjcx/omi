import Foundation

/// Turns a growing transcript into the smallest keystroke edit that makes the
/// already-typed text match it.
///
/// Speech recognizers revise: "wright" becomes "write" a fragment later. Typing
/// only the appended suffix would leave the wrong word on screen forever, and
/// retyping the whole payload on every update would flood the focused app. The
/// planner keeps the common prefix and rewrites only the divergent tail, so a
/// pure append (the common case) costs zero deletions.
struct VoiceTypeStreamPlanner {

  struct Edit: Equatable {
    /// Characters to delete before inserting. Never exceeds what this planner
    /// has itself typed.
    let backspaces: Int
    let insertion: String

    var isEmpty: Bool { backspaces == 0 && insertion.isEmpty }
    static let none = Edit(backspaces: 0, insertion: "")
  }

  /// How far back a correction may reach. A recognizer that revises a word from
  /// half a sentence ago is not worth the damage: erasing and retyping that much
  /// text is violent to watch, and it fights the user if they have started
  /// editing behind the caret. Corrections near the moving edge are what make
  /// dictation feel accurate; corrections far behind it just look broken.
  static let maxRewindWords = 3

  /// What has actually been emitted to the focused app so far this turn.
  private(set) var typed: String = ""

  /// - Parameter rewritesFreely: lift the rewind limit. For text that will not
  ///   move again — a finished utterance from the stronger streaming model, or
  ///   the closing decode — a correction is worth its cost wherever it lands,
  ///   and leaving the screen out of step with the record would make every
  ///   later edit diff against text that is not there.
  mutating func plan(for desired: String, rewritesFreely: Bool = false) -> Edit {
    guard desired != typed else { return .none }

    var shared = 0
    var typedIndex = typed.startIndex
    var desiredIndex = desired.startIndex
    while typedIndex < typed.endIndex, desiredIndex < desired.endIndex,
      typed[typedIndex] == desired[desiredIndex]
    {
      shared += 1
      typedIndex = typed.index(after: typedIndex)
      desiredIndex = desired.index(after: desiredIndex)
    }

    let backspaces = typed.count - shared
    if !rewritesFreely, backspaces > Self.rewindLimit(typed) {
      // Too far back to correct. Keep what is on screen and append only what
      // the new transcript adds beyond it, so the tail keeps flowing instead of
      // the whole sentence being rewritten.
      guard desired.count > typed.count else { return .none }
      let insertion = String(desired.dropFirst(typed.count))
      typed += insertion
      return Edit(backspaces: 0, insertion: insertion)
    }

    let edit = Edit(backspaces: backspaces, insertion: String(desired[desiredIndex...]))
    typed = desired
    return edit
  }

  /// Characters within the last `maxRewindWords` words of what is on screen.
  private static func rewindLimit(_ text: String) -> Int {
    let words = text.split(separator: " ", omittingEmptySubsequences: false)
    guard words.count > maxRewindWords else { return text.count }
    return words.suffix(maxRewindWords).joined(separator: " ").count
  }

  /// Forgets the turn's history without touching the focused app. Used when a
  /// turn ends: the next turn must never delete the previous turn's text.
  mutating func reset() {
    typed = ""
  }
}
