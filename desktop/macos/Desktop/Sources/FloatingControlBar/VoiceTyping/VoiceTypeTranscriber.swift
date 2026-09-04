import Foundation

/// The text one recognizer produced for a complete utterance, and which one.
struct VoiceTypeTranscript: Equatable, Sendable {
  let text: String
  let source: Source

  enum Source: String, Equatable, Sendable {
    /// The backend batch recognizer (`/v2/voice-message/transcribe`): the whole
    /// utterance in one request, routed to the strongest model the account has,
    /// biased by the keywords visible on screen.
    case cloudBatch = "cloud_batch"
    /// The on-device Parakeet model. The answer when there is no network, and
    /// whenever the cloud is slower than the budget or comes back empty.
    case onDevice = "on_device"
  }
}

/// Produces the one transcript a paste-on-release dictation is built from.
///
/// Both recognizers are started together rather than one after the other, and
/// that is the whole trick to being accurate *and* fast. On-device Parakeet runs
/// at roughly 100x realtime, so a ten-second hold is decoded in about a hundred
/// milliseconds — it is finished before the network has finished opening a
/// connection, and it costs the turn nothing. Having its answer already in hand
/// is what allows the wait on the stronger cloud pass to be bounded: the budget
/// can expire without the dictation ever degrading to nothing.
///
/// So the user gets the cloud transcript whenever the cloud can answer within
/// the budget, and the on-device transcript in every other case, and never an
/// empty paste because a recognizer was slow.
struct VoiceTypeTranscriber: Sendable {

  /// How long key-up waits for the cloud before pasting the on-device answer.
  ///
  /// Generous on purpose. This is the only latency the new design has, it is
  /// paid once per dictation rather than continuously, and a wrong word costs
  /// the user more time to fix by hand than three seconds of waiting.
  static let defaultBudget: TimeInterval = 3

  typealias Cloud = @Sendable (Data, [String]) async throws -> String?
  typealias OnDevice = @Sendable (Data) async -> String?
  typealias Reachability = @Sendable () async -> Bool
  typealias Sleeper = @Sendable (TimeInterval) async -> Void

  /// Why a turn did not use the cloud transcript. Reported so a dictation that
  /// silently got the weaker model is visible in telemetry rather than only in
  /// the user's document.
  enum Degradation: String, Equatable, Sendable {
    case network
    case timeout
    case error
    /// The cloud answered, with nothing in it.
    case empty
  }

  private let cloud: Cloud
  private let onDevice: OnDevice
  private let isReachable: Reachability
  private let budget: TimeInterval
  private let sleep: Sleeper

  init(
    cloud: @escaping Cloud,
    onDevice: @escaping OnDevice,
    isReachable: @escaping Reachability,
    budget: TimeInterval = VoiceTypeTranscriber.defaultBudget,
    sleep: @escaping Sleeper = { seconds in
      try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
    }
  ) {
    self.cloud = cloud
    self.onDevice = onDevice
    self.isReachable = isReachable
    self.budget = budget
    self.sleep = sleep
  }

  struct Outcome: Equatable, Sendable {
    let transcript: VoiceTypeTranscript?
    /// Set when the cloud transcript was wanted and not used.
    let degradation: Degradation?
  }

  func transcribe(_ audio: Data, keywords: [String]) async -> Outcome {
    guard !audio.isEmpty else { return Outcome(transcript: nil, degradation: nil) }

    async let localText = onDevice(audio)

    var cloudResult: CloudResult = .unreachable
    if await isReachable() {
      cloudResult = await cloudWithinBudget(audio, keywords: keywords)
    }
    let local = Self.cleaned(await localText)

    if case .text(let text) = cloudResult, let cleaned = Self.cleaned(text) {
      return Outcome(
        transcript: VoiceTypeTranscript(text: cleaned, source: .cloudBatch), degradation: nil)
    }
    let degradation = cloudResult.degradation
    guard let local else { return Outcome(transcript: nil, degradation: degradation) }
    return Outcome(
      transcript: VoiceTypeTranscript(text: local, source: .onDevice), degradation: degradation)
  }

  private enum CloudResult: Sendable {
    case text(String)
    case unreachable
    case timedOut
    case failed
    case empty

    var degradation: Degradation {
      switch self {
      case .text, .empty: return .empty
      case .unreachable: return .network
      case .timedOut: return .timeout
      case .failed: return .error
      }
    }
  }

  /// Races the cloud request against the budget. A slow recognizer is abandoned
  /// rather than waited on, because the on-device answer is already sitting
  /// there and pasting it now beats pasting a better one much later.
  private func cloudWithinBudget(_ audio: Data, keywords: [String]) async -> CloudResult {
    await withTaskGroup(of: CloudResult.self) { group in
      group.addTask { [cloud] in
        do {
          guard let text = try await cloud(audio, keywords), !text.isEmpty else { return .empty }
          return .text(text)
        } catch {
          return .failed
        }
      }
      group.addTask { [sleep, budget] in
        await sleep(budget)
        return .timedOut
      }
      let first = await group.next() ?? .failed
      group.cancelAll()
      return first
    }
  }

  private static func cleaned(_ text: String?) -> String? {
    guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty
    else { return nil }
    return trimmed
  }
}
