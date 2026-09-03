import Foundation

/// **Super Mode's voice path: the hub still hears you, Super Mode still answers.**
///
/// Push-to-talk on this app is not "transcribe, then ask". The turn opens a Gemini Live session that
/// hears the audio and answers from inside it; the transcript is a by-product of that session, and
/// there is no configuration in which the hub transcribes without answering — `responseModalities`
/// is `["AUDIO"]` and that *is* the session.
///
/// So Super Mode does not change how the words are captured, and an earlier attempt that did is the
/// reason this file exists: forcing the separate speech-to-text route moved capture onto a backend
/// relay that is not always reachable, and push-to-talk stopped producing any words at all. The
/// route, the microphone, and the transcription are exactly what they were.
///
/// What changes is only who answers. The hub's spoken reply is withheld through the presentation
/// policy every provider-output path already consults, its turn is cancelled as soon as the
/// transcript is final so it does not keep generating a reply nobody will hear, and the words it
/// heard are answered by Super Mode — this screen and this session, nothing else — and spoken back
/// through the same playback service every other voice answer uses.
@MainActor
extension RealtimeHubController {

  /// True while a Super Mode voice turn should own the answer. Read by the output-presentation
  /// policy, so a suppressed hub reply and a Super Mode handoff can never disagree about who is
  /// speaking.
  static var superModeOwnsVoiceAnswer: Bool { SuperModeController.shared.isOn }

  /// Hands one finalized hub transcript to Super Mode. Idempotent per turn: the provider can emit
  /// more than one final input transcript for a single hold, and answering twice would both charge
  /// the user's key twice and talk over itself.
  func handOffFinalTranscriptToSuperModeIfNeeded() {
    // **Every decline says why.** The first version returned silently from four separate guards, and
    // when speaking produced no answer at all the log had nothing in it — the whole feature was
    // invisible in exactly the situation it needed to be debugged from. A refusal nobody can read is
    // a refusal nobody can fix.
    guard Self.superModeOwnsVoiceAnswer else { return }
    guard let turnID = VoiceTurnCoordinator.shared.activeTurnID else {
      log("RealtimeHub: Super Mode handoff skipped — no active voice turn")
      return
    }
    guard superModeHandoffTurnID != turnID else { return }
    // **Only once the button is up.** "Final" here is the provider's word about a span of speech,
    // not about the hold: a pause long enough to trip voice-activity detection finalizes a
    // transcript while the user is still talking. Handing off then would cancel the turn mid
    // sentence and answer half a question.
    //
    // The test is `!isRecording`, not a named post-release phase. A hub turn lands in
    // `.awaitingResponse` on release and a transcription turn lands in `.finalizing`, so naming
    // either one silently means "only on the other route" — the first version of this guard named
    // `.finalizing` and would therefore never have fired for the hub, which is the only route this
    // file exists for.
    guard let phase = VoiceTurnCoordinator.shared.activeTurn?.phase, !phase.isRecording else {
      log("RealtimeHub: Super Mode deferring handoff — transcript finalized while still recording")
      return
    }
    let question = turnTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
    // A hold that produced no words is a silent turn, not a question. Letting it through would ask
    // Gemini about the screen with an empty prompt and bill the user for the screenshot.
    guard !question.isEmpty else {
      log("RealtimeHub: Super Mode handoff skipped — no transcript yet for this turn")
      return
    }
    superModeHandoffTurnID = turnID

    // Stop the hub before it finishes composing a reply that is already suppressed. Cancelling is
    // the same call the reducer makes for any abandoned hub turn, so the coordinator reaches its
    // ordinary terminal rather than a state only this feature can produce.
    _ = cancelTurn(turnID: turnID)

    log("RealtimeHub: Super Mode owns this voice answer — hub reply suppressed, handing off transcript")

    Task { @MainActor in
      // Streamed for the same reason the typed path is, and it matters more here: speech synthesis
      // can start on the first sentence instead of waiting for the last token to be generated.
      let answer = await SuperModeController.shared.answer(to: question) { fragment in
        guard Self.superModeOwnsVoiceAnswer, self.superModeHandoffTurnID == turnID else { return }
        FloatingControlBarManager.shared.streamSuperModeVoiceAnswer(
          question: question, fragment: fragment)
      }
      // The mode can be switched off, or another turn started, while Gemini is answering. Finishing
      // then would deliver a reply to a question the user has already moved on from.
      guard Self.superModeOwnsVoiceAnswer, self.superModeHandoffTurnID == turnID else { return }
      FloatingControlBarManager.shared.presentSuperModeVoiceAnswer(question: question, answer: answer)
    }
  }
}
