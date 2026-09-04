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
    planner.reset()
    stabilizer.reset()
  }

  /// Feeds the whole utterance heard so far. Returns whether this turn belongs
  /// to voice typing.
  ///
  /// - Parameter isSettled: true only for the closing transcript, which is not
  ///   going to move again and so is typed in full rather than held back a word.
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
    emit(payload)
    return true
  }

  /// Feeds the final transcript and flushes any text the live stream never
  /// delivered. Returns what the turn dictated, if anything.
  @discardableResult
  func finish(transcript: String) -> Completion {
    let claimed = update(transcript: transcript, isSettled: true)
    // Read before the reset below clears it: `typed` is the exact text that
    // reached the focused app, which is what the transcript should record.
    let completion: Completion = claimed ? .typed(planner.typed) : .none
    latch = .none
    planner.reset()
    stabilizer.reset()
    return completion
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
    let completion: Completion = claimed ? .typed(planner.typed) : .none
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
    log("VoiceTypeSession: typing turn armed")
    return true
  }

  private func emit(_ payload: String) {
    let edit = planner.plan(for: payload)
    guard !edit.isEmpty else { return }
    sink.deleteBackward(edit.backspaces)
    sink.insert(edit.insertion)
  }
}
