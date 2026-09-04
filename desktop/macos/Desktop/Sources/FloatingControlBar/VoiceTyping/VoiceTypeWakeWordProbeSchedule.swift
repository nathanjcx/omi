import Foundation

/// When, during a hold, the opening of the turn is decoded once to listen for
/// the wake word.
///
/// Nothing is typed while the key is held, so this is not about latency. It is
/// about spend and about feedback: a dictation on the realtime-hub route would
/// otherwise stream every minute of the hold to a model whose answer is going
/// to be cancelled, and the user would get no sign that "type" was heard until
/// the paste. Two probes at most, scheduled by *voiced* audio rather than by
/// time — a locked turn can open with seconds of room tone — and each decodes
/// only the first few seconds, so the cost is bounded however long the hold.
///
/// The probe is advisory. The closing transcript decides the turn on its own,
/// so a missed or misheard probe costs nothing but the early hub release.
struct VoiceTypeWakeWordProbeSchedule: Equatable {

  /// Voiced bytes (16 kHz s16le) at which each probe runs: enough for "type"
  /// plus a word, then enough for the parser to be sure.
  static let voicedByteThresholds = [Int(1.2 * 32_000), Int(2.6 * 32_000)]
  /// The most audio a probe decodes. The wake word opens the utterance; the
  /// rest of a long hold is not needed to find it.
  static let maxProbeBytes = 6 * 32_000

  private(set) var voicedBytes = 0
  private(set) var probesTaken = 0
  private(set) var isDecided = false

  /// Feeds one mic chunk. Returns true when a probe is due now.
  mutating func observe(chunk: Data) -> Bool {
    guard !isDecided, probesTaken < Self.voicedByteThresholds.count else { return false }
    voicedBytes += VoiceTypeAudioTrim.speechBytes(in: chunk)
    guard voicedBytes >= Self.voicedByteThresholds[probesTaken] else { return false }
    probesTaken += 1
    return true
  }

  /// The question is settled either way (claimed, rejected, or blocked); no
  /// further probes.
  mutating func decide() {
    isDecided = true
  }

  mutating func reset() {
    self = VoiceTypeWakeWordProbeSchedule()
  }
}
