import ApplicationServices
import Foundation

/// One push-to-talk turn's worth of voice typing.
///
/// The session is the only thing that decides whether a turn dictates into the
/// focused app instead of asking Omi. That decision latches in one direction
/// only: once a turn is typing it stays typing, because a later transcript
/// revision may change the words but must never change their destination.
/// *Not* typing never latches — an early decode is one or two characters of a
/// half-spoken word, which is not evidence about a sentence the user has barely
/// started. Latching on it is what silently disabled the whole feature in live
/// testing: a 2-character first decode rejected the turn before "Type" existed.
///
/// Callers feed `update` on every transcript change and route the turn to chat
/// only while `claimsTurn` is false.
@MainActor
final class VoiceTypeSession {

  private let sink: KeystrokeSink
  private let isAccessibilityTrusted: () -> Bool
  private var planner = VoiceTypeStreamPlanner()
  private var stabilizer = VoiceTypeStabilizer()

  private enum Latch {
    case none
    case typing
    /// A type command that cannot be delivered (no Accessibility grant). Latched
    /// so one denied turn reports one fallback, not one per decode.
    case blocked
  }

  /// What a finished turn delivered. The caller journals `typed` so the dictated
  /// sentence joins the conversation history; a turn that never dictated has
  /// nothing to record.
  enum Completion: Equatable {
    case none
    case typed(String)
  }

  private var latch: Latch = .none
  /// Typed ahead of the first word when the caret was sitting right after a
  /// word, so a dictation that continues a line does not run into it. Part of
  /// what is on screen (the planner diffs against it) but not part of what the
  /// turn dictated.
  private var leadingSeparator = ""
  /// Where the dictation was aimed when it armed. Keystrokes are posted only
  /// while that is still the frontmost application; otherwise the turn pauses
  /// and catches up when focus returns. Observed live: the user clicked the
  /// Omi dock icon mid-hold and two stream commits rewrote text inside Omi's
  /// own window instead of the document.
  private var armedFocusTarget: String?
  private var pausedForFocus = false
  /// Set while a turn that has already been closed is still flushing its last
  /// words. Teardown must not reset the planner underneath that flush, or the
  /// diff would be computed against an empty buffer and retype the whole
  /// sentence into the user's document.
  private var isFlushing = false
  /// Bumped by every `begin`, so a flush belonging to a finished turn can never
  /// write into the turn that replaced it.
  private var generation = 0

  /// True once this turn has actually dictated. The caller uses it to suppress
  /// the chat dispatch — so a turn is only ever taken away from Omi when text
  /// really did land in the focused app.
  var claimsTurn: Bool { latch == .typing }

  /// Characters delivered to the focused app so far this turn.
  var typedCount: Int { planner.typed.count }

  /// The dictated text on screen, without the separator typed ahead of it.
  private var dictatedText: String {
    String(planner.typed.dropFirst(leadingSeparator.count))
  }

  init(
    sink: KeystrokeSink = CGEventKeystrokeSink(),
    isAccessibilityTrusted: @escaping () -> Bool = { AXIsProcessTrusted() }
  ) {
    self.sink = sink
    self.isAccessibilityTrusted = isAccessibilityTrusted
  }

  func begin() {
    generation &+= 1
    isFlushing = false
    latch = .none
    leadingSeparator = ""
    armedFocusTarget = nil
    pausedForFocus = false
    planner.reset()
    stabilizer.reset()
  }

  /// Feeds the whole utterance heard so far. Returns whether this turn belongs
  /// to voice typing.
  ///
  /// - Parameter isSettled: true for text that is not going to move again — the
  ///   closing transcript, or a stretch a streaming recognizer has finished. It
  ///   is typed in full rather than held back a word, and it may correct what is
  ///   already on screen however far back that reaches.
  @discardableResult
  func update(transcript: String, isSettled: Bool = false) -> Bool {
    guard latch != .blocked else { return false }
    let usable =
      isSettled ? stabilizer.settle(transcript) : stabilizer.stabilized(transcript)
    guard case .typing(let payload) = VoiceTypeCommandParser.decide(usable) else {
      // Undecided or not-a-command: nothing to type *yet*. A turn already typing
      // keeps its claim; one that never armed stays available to chat.
      return claimsTurn
    }
    guard armIfNeeded() else { return false }
    emit(payload, rewritesFreely: isSettled)
    return true
  }

  /// Feeds the final transcript and flushes any text the live stream never
  /// delivered. Returns what the turn dictated, if anything.
  @discardableResult
  func finish(transcript: String) -> Completion {
    let claimed = update(transcript: transcript, isSettled: true)
    // Read before the reset below clears it: `typed` is the exact text that
    // reached the focused app, which is what the transcript should record.
    let completion: Completion = claimed ? .typed(dictatedText) : .none
    latch = .none
    planner.reset()
    stabilizer.reset()
    return completion
  }

  /// Whether `token` still names the open flush window. Lets a caller that
  /// waits for a late transcript check it is still closing the turn it opened,
  /// rather than one that has since been replaced.
  func isFlushing(token: Int) -> Bool {
    isFlushing && token == generation
  }

  /// Opens the post-commit flush window. Returns the token `endFlush` must
  /// present, so a flush cannot land in a later turn.
  func beginFlush() -> Int {
    isFlushing = true
    return generation
  }

  /// Types whatever the closing decode heard beyond what the live probes already
  /// delivered, then ends the turn. Returns what the turn dictated, so the
  /// caller journals the completed sentence rather than the partial one the
  /// probes had delivered when the key came up.
  @discardableResult
  func endFlush(token: Int, finalTranscript: String?) -> Completion {
    guard token == generation, isFlushing else { return .none }
    isFlushing = false
    var claimed = claimsTurn
    if let finalTranscript {
      claimed = update(transcript: finalTranscript, isSettled: true) || claimed
    }
    let completion: Completion = claimed ? .typed(dictatedText) : .none
    latch = .none
    planner.reset()
    stabilizer.reset()
    return completion
  }

  /// Ends the turn without typing anything further (cancel, error, teardown).
  func abandon() {
    guard !isFlushing else { return }
    latch = .none
    planner.reset()
    stabilizer.reset()
  }

  private func armIfNeeded() -> Bool {
    if latch == .typing { return true }
    guard isAccessibilityTrusted() else {
      latch = .blocked
      log("VoiceTypeSession: Accessibility not granted — releasing turn to chat")
      DesktopDiagnosticsManager.shared.recordFallback(
        area: "voice_typing",
        from: "keystroke_injection",
        to: "chat_query",
        reason: "policy",
        outcome: .degraded)
      return false
    }
    latch = .typing
    // Decided once, at arming, from where the caret is right now: the first
    // word must not land flush against the word before it ("voiceI think").
    leadingSeparator = sink.caretFollowsWordCharacter() ? " " : ""
    armedFocusTarget = sink.focusTarget()
    log("VoiceTypeSession: typing turn armed" + (leadingSeparator.isEmpty ? "" : " (continuing a line)"))
    return true
  }

  private func emit(_ payload: String, rewritesFreely: Bool) {
    // The separator goes in with the first word, never on its own: a bare
    // wake word must leave nothing behind.
    guard !payload.isEmpty else { return }
    if let armed = armedFocusTarget, let current = sink.focusTarget(), current != armed {
      if !pausedForFocus {
        pausedForFocus = true
        log("VoiceTypeSession: focus left the dictation target — typing paused until it returns")
      }
      return
    }
    if pausedForFocus {
      pausedForFocus = false
      log("VoiceTypeSession: focus returned — typing resumes")
    }
    let before = planner.typed.count
    let edit = planner.plan(for: leadingSeparator + payload, rewritesFreely: rewritesFreely)
    guard !edit.isEmpty else { return }
    if edit.backspaces >= 20 {
      // Shape only, never text: a rewrite this large is either a correction
      // the user will see as a flash or a planner/screen divergence.
      log(
        "VoiceTypeSession: large edit — typed=\(before) backspaces=\(edit.backspaces) "
          + "insert=\(edit.insertion.count) settled=\(rewritesFreely)")
    }
    sink.deleteBackward(edit.backspaces)
    sink.insert(edit.insertion)
  }
}
