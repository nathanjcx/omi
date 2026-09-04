import Foundation

/// Trims the quiet lead-in from a push-to-talk buffer before it is decoded.
///
/// A hold starts when the key goes down, not when the user starts talking, and
/// on a locked turn that gap can be seconds long. Handing that silence to the
/// recognizer does not produce an empty string — it produces invented words,
/// and voice typing reads the *start* of the utterance to decide whether the
/// turn dictates at all. Measured live: 9 s of room tone decoded as 43
/// characters of nonsense, which rejected the turn before "Type" was ever said.
enum VoiceTypeAudioTrim {

  /// RMS below this (of Int16 full scale) is room tone, not speech.
  static let speechRMSThreshold: Double = 350
  private static let windowSamples = 320  // 20 ms at 16 kHz
  /// Kept in front of the first loud window so the decoder still hears the
  /// attack of the first consonant.
  private static let preRollSamples = 1_600  // 100 ms
  /// Kept after the last loud window so a trailing fricative ("...pass") is not
  /// clipped off the end of the utterance.
  private static let postRollSamples = 3_200  // 200 ms

  /// The least voiced audio worth decoding on its own: 0.5 s at 16 kHz s16le.
  ///
  /// Below this there is no word to recover, only a syllable's tail or a
  /// breath, and the on-device decoder answers those with an invented phrase
  /// ("Thank you." — observed live, twice in one hold).
  static let minimumDecodableSpeechBytes = 16_000

  /// Bytes of `pcm16k` that lie in 20 ms windows at speech level — how much
  /// of a buffer is actually voice, as opposed to the pauses around it.
  static func speechBytes(in pcm16k: Data) -> Int {
    let sampleCount = pcm16k.count / 2
    guard sampleCount >= windowSamples else { return 0 }
    return pcm16k.withUnsafeBytes { raw -> Int in
      let samples = raw.bindMemory(to: Int16.self)
      var loudWindows = 0
      var start = 0
      while start + windowSamples <= sampleCount {
        var sumSquares = 0.0
        for index in start..<(start + windowSamples) {
          let value = Double(Int16(littleEndian: samples[index]))
          sumSquares += value * value
        }
        if (sumSquares / Double(windowSamples)).squareRoot() >= speechRMSThreshold { loudWindows += 1 }
        start += windowSamples
      }
      return loudWindows * windowSamples * 2
    }
  }

  /// - Parameter pcm16k: raw s16le 16 kHz mono.
  /// - Returns: the buffer from just before the first speech onward, or empty
  ///   when the whole buffer is quiet.
  static func trimmingLeadingSilence(_ pcm16k: Data) -> Data {
    let sampleCount = pcm16k.count / 2
    guard sampleCount >= windowSamples else { return Data() }

    return pcm16k.withUnsafeBytes { raw -> Data in
      let samples = raw.bindMemory(to: Int16.self)
      var window = 0
      while (window + 1) * windowSamples <= sampleCount {
        var sumSquares = 0.0
        let start = window * windowSamples
        for index in start..<(start + windowSamples) {
          let value = Double(Int16(littleEndian: samples[index]))
          sumSquares += value * value
        }
        if (sumSquares / Double(windowSamples)).squareRoot() >= speechRMSThreshold {
          let firstSample = max(0, start - preRollSamples)
          // Relative to `startIndex`: a `Data` produced by a slice does not
          // start at zero, and an absolute range would trap.
          let lower = pcm16k.startIndex + firstSample * 2
          return pcm16k.subdata(in: lower..<pcm16k.endIndex)
        }
        window += 1
      }
      return Data()
    }
  }

  /// - Returns: the buffer up to just after the last speech, or empty when the
  ///   whole buffer is quiet.
  ///
  /// A hold ends when the key comes up, not when the user stops talking, so the
  /// tail of a turn is room tone plus the click of the key. A recognizer handed
  /// a complete utterance with that on the end does not return the utterance —
  /// it appends a phrase for the silence, which is exactly the invented "Thank
  /// you." the leading trim exists to prevent at the other end.
  static func trimmingTrailingSilence(_ pcm16k: Data) -> Data {
    let sampleCount = pcm16k.count / 2
    guard sampleCount >= windowSamples else { return Data() }

    return pcm16k.withUnsafeBytes { raw -> Data in
      let samples = raw.bindMemory(to: Int16.self)
      var window = sampleCount / windowSamples
      while window > 0 {
        let start = (window - 1) * windowSamples
        var sumSquares = 0.0
        for index in start..<(start + windowSamples) {
          let value = Double(Int16(littleEndian: samples[index]))
          sumSquares += value * value
        }
        if (sumSquares / Double(windowSamples)).squareRoot() >= speechRMSThreshold {
          let lastSample = min(sampleCount, start + windowSamples + postRollSamples)
          // Rebuilt rather than sliced: a `Data` slice keeps the parent's
          // indices, and every consumer downstream indexes from zero.
          return Data(pcm16k.prefix(lastSample * 2))
        }
        window -= 1
      }
      return Data()
    }
  }

  /// Both ends at once — what a complete utterance is handed to a recognizer as.
  static func trimmingSilence(_ pcm16k: Data) -> Data {
    trimmingTrailingSilence(trimmingLeadingSilence(pcm16k))
  }
}
