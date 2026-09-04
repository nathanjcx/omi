import Foundation

/// Chooses which transcript drives the keystrokes when two recognizers are
/// decoding the same dictation.
///
/// On-device Parakeet starts instantly and needs no network, but it is the
/// smaller model. The backend streaming surface leads with a stronger one
/// (`modulate-velma-2`, then `soniox` / `dg-nova-3`) and cannot produce a word
/// until a socket is open and audio has made a round trip.
///
/// Typing the local decode first and handing over the moment the cloud has
/// anything is what makes dictation feel immediate *and* end up accurate:
/// `VoiceTypeStreamPlanner` rewrites only the divergent tail, so the handover
/// costs a few characters rather than a retype.
enum VoiceTypeTranscriptSource: Equatable {
  case onDevice
  case cloud

  case hub

  /// - Parameter cloudFailed: set only when the stream actually reported a
  ///   failure. Falling back on real evidence rather than on a transcript that
  ///   merely stopped growing is what keeps a mid-turn stream death from
  ///   rewriting text the user already accepted.
  ///
  /// Exactly one source wins, and the caller must feed only the winner onward.
  /// The stabilizer downstream releases text once two *consecutive* decodes
  /// agree, so interleaving two recognizers' transcripts stops it agreeing with
  /// itself and it releases nothing at all — observed live as a dictation that
  /// typed nothing while every probe had clearly heard the wake word.
  ///
  /// The realtime hub ranks last: it reports the user's own words late and
  /// erratically, so it is only better than having no transcript at all.
  static func preferred(
    onDevice: String, hub: String, cloud: String, cloudFailed: Bool
  ) -> VoiceTypeTranscriptSource {
    if !cloudFailed, !cloud.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      return .cloud
    }
    if !onDevice.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .onDevice }
    return hub.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .onDevice : .hub
  }

  /// The transcript to type, resolved across every recognizer.
  static func transcript(
    onDevice: String, hub: String, cloud: String, cloudFailed: Bool
  ) -> String {
    switch preferred(onDevice: onDevice, hub: hub, cloud: cloud, cloudFailed: cloudFailed) {
    case .onDevice: return onDevice
    case .cloud: return cloud
    case .hub: return hub
    }
  }
}
