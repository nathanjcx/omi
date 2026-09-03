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

  /// What has actually been emitted to the focused app so far this turn.
  private(set) var typed: String = ""

  mutating func plan(for desired: String) -> Edit {
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

    let edit = Edit(
      backspaces: typed.count - shared,
      insertion: String(desired[desiredIndex...]))
    typed = desired
    return edit
  }

  /// Forgets the turn's history without touching the focused app. Used when a
  /// turn ends: the next turn must never delete the previous turn's text.
  mutating func reset() {
    typed = ""
  }
}
