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
          return pcm16k.subdata(in: (firstSample * 2)..<pcm16k.count)
        }
        window += 1
      }
      return Data()
    }
  }
}
