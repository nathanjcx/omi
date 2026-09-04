import ApplicationServices
import Foundation

/// Delivers one finished dictation into the focused app.
///
/// This used to be the most intricate file in the feature and is now the
/// simplest, which is the point of pasting on release. While text was typed as
/// the user spoke, the session had to own a latch (is this turn a dictation?),
/// a stabilizer (which words have stopped moving?), an edit planner (what is
/// the smallest keystroke diff?), a focus pause, a flush window, and a
/// generation counter so a flush could not write into the turn that replaced
/// it. Every one of those existed to make a *partial* answer safe to put on
/// screen. There are no partial answers any more, so there is nothing to
/// stabilize, diff, or take back — one insertion, once, of text that is final.
///
/// What is left is the two decisions that still have to be made at the moment
/// of delivery, because neither can be answered any earlier: whether this
/// machine will let us synthesize input at all, and whether the text needs a
/// separating space in front of it.
@MainActor
final class VoiceTypeSession {

  /// What a finished turn delivered. The caller journals `typed` so the
  /// dictated sentence joins the conversation history; a turn that delivered
  /// nothing has nothing to record.
  enum Completion: Equatable {
    case none
    case typed(String)
  }

  private let inserter: VoiceTypeTextInserter
  private let isAccessibilityTrusted: () -> Bool
  private let selfBundleIdentifier: String?
  private let recordFallback: (String, String, String) -> Void

  /// Characters delivered by the last completed turn, for diagnostics.
  private(set) var deliveredCount = 0

  init(
    inserter: VoiceTypeTextInserter = PasteboardTextInserter(),
    isAccessibilityTrusted: @escaping () -> Bool = { AXIsProcessTrusted() },
    selfBundleIdentifier: String? = Bundle.main.bundleIdentifier,
    recordFallback: @escaping (String, String, String) -> Void = { from, to, reason in
      DesktopDiagnosticsManager.shared.recordFallback(
        area: "voice_typing", from: from, to: to, reason: reason, outcome: .degraded)
    }
  ) {
    self.inserter = inserter
    self.isAccessibilityTrusted = isAccessibilityTrusted
    self.selfBundleIdentifier = selfBundleIdentifier
    self.recordFallback = recordFallback
  }

  /// Whether a dictation could be delivered at all. Asked before the turn
  /// spends anything on transcription: with no Accessibility grant there is
  /// nowhere for the text to go, and the turn is better off as a question.
  func canDeliver() -> Bool { isAccessibilityTrusted() }

  /// Puts `payload` at the caret in one insertion.
  ///
  /// - Returns: the text that actually reached the focused app, without the
  ///   separator typed ahead of it — that is on screen but is not part of what
  ///   the user dictated, so it must not enter the journal.
  @discardableResult
  func deliver(payload: String) -> Completion {
    let text = payload.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return .none }

    guard isAccessibilityTrusted() else {
      log("VoiceTypeSession: Accessibility not granted — dictation cannot be delivered")
      recordFallback("keystroke_injection", "chat_query", "policy")
      return .none
    }

    // Omi's own window is the one place a dictation must never land. The
    // floating bar is a non-activating panel, so during a hold the frontmost
    // app is normally still the user's own — but a dock click mid-hold brought
    // Omi forward and the dictation rewrote text inside Omi's chat composer.
    if let selfBundleIdentifier, inserter.frontmostBundleIdentifier() == selfBundleIdentifier {
      log("VoiceTypeSession: Omi is frontmost — refusing to dictate into our own window")
      recordFallback("keystroke_injection", "discarded", "policy")
      return .none
    }

    // Decided here, from where the caret is right now: the first word must not
    // land flush against the word before it ("voiceI think").
    let separator = inserter.caretFollowsWordCharacter() ? " " : ""
    switch inserter.insert(separator + text) {
    case .pasted:
      deliveredCount = text.count
      log("VoiceTypeSession: pasted \(text.count) characters")
      return .typed(text)
    case .typed:
      deliveredCount = text.count
      log("VoiceTypeSession: pasteboard refused — synthesized \(text.count) characters instead")
      recordFallback("pasteboard_insert", "keystroke_injection", "other")
      return .typed(text)
    case .failed:
      log("VoiceTypeSession: dictation could not be delivered")
      recordFallback("keystroke_injection", "discarded", "other")
      return .none
    }
  }
}
