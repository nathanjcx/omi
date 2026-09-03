import Foundation

/// **Super Mode's interception point, kept out of `ChatProvider` proper.**
///
/// `ChatProvider.sendMessage` is the one funnel every composer in the app sends through, which is
/// exactly why Super Mode intercepts at its top: the mode's promise is that no memory, transcript or
/// kernel tool reaches the model, and that cannot be expressed as a flag passed *into* a turn that
/// assembles all three. It has to be a turn that never starts.
///
/// The two functions that decide and perform that live here rather than inside an already very large
/// file, so the interception reads as one idea in one place — and so `ChatProvider` does not grow
/// again for a feature that is not really about chat.
extension ChatProvider {

  /// The surfaces that show the Super Mode bolt, and therefore the only ones it may answer for. An
  /// onboarding or task-agent turn has its own scripted job and no way to see that the mode is on.
  static func superModeAnswers(_ turnOwner: ChatTurnOwner) -> Bool {
    switch turnOwner {
    case .mainChat, .floatingDefault, .floatingVoice: return true
    case .taskChat, .agentPill: return false
    }
  }

  /// Renders the exchange locally. It is deliberately not synced, not journaled, and not given a
  /// server id: a Super Mode answer is scoped to the session that asked for it, and writing it into
  /// the canonical transcript is how it would leak back as context into an ordinary turn later.
  @discardableResult
  func answerWithSuperMode(
    _ question: String,
    clientTurnId: String,
    turnOwner: ChatTurnOwner
  ) async -> String? {
    messages.append(
      ChatMessage(
        clientTurnId: clientTurnId, text: question, sender: .user, turnOwner: turnOwner))
    let placeholderId = UUID().uuidString
    messages.append(
      ChatMessage(
        id: placeholderId, clientTurnId: clientTurnId, text: "", sender: .ai, isStreaming: true,
        turnOwner: turnOwner))

    // Deltas land in the placeholder as they arrive, which is the whole reason the request streams:
    // the reader starts reading at the first token instead of at the last one. `isStreaming` stays
    // true throughout so the transcript renders it as a live answer, exactly like a kernel turn.
    let answer = await SuperModeController.shared.answer(to: question) { [weak self] fragment in
      guard let self, let index = self.messages.firstIndex(where: { $0.id == placeholderId })
      else { return }
      self.messages[index].text += fragment
    }
    guard let index = messages.firstIndex(where: { $0.id == placeholderId }) else { return answer }
    // Assign rather than append: an error answer never streamed, so the accumulated text is either
    // exactly this string already or empty.
    messages[index].text = answer
    messages[index].isStreaming = false
    return answer
  }

}
