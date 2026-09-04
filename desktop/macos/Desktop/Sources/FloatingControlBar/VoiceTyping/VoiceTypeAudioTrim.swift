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

  /// Whether the last `seconds` of the buffer are near-silence — the speaker
  /// has paused, so text can be committed without cutting a word in half.
  ///
  /// Uses the same threshold as the leading trim: what counts as room tone at
  /// the start of a turn counts as a pause in the middle of one.
  static func endsQuiet(_ pcm16k: Data, seconds: Double = 0.35) -> Bool {
    let tailSamples = Int(seconds * 16_000)
    let sampleCount = pcm16k.count / 2
    guard sampleCount >= tailSamples, tailSamples > 0 else { return false }
    let start = (sampleCount - tailSamples) * 2
    return pcm16k.withUnsafeBytes { raw -> Bool in
      let samples = raw.bindMemory(to: Int16.self)
      var sumSquares = 0.0
      for index in (start / 2)..<sampleCount {
        let value = Double(Int16(littleEndian: samples[index]))
        sumSquares += value * value
      }
      return (sumSquares / Double(tailSamples)).squareRoot() < speechRMSThreshold
    }
  }

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

  /// The first quiet 20 ms window at or after `offset`, as a byte offset, if
  /// one begins within `lookaheadSeconds`.
  ///
  /// Used to move a commit seam onto a pause. A streaming recognizer's
  /// utterance `end` can land a few tens of milliseconds before the word it
  /// closes has finished sounding; cutting there hands the next window the
  /// word's last syllable, which it spells as a word of its own ("thinking" →
  /// "thinking ng"). Sliding the seam to the next quiet window makes the cut
  /// where a local commit would have made it.
  static func quietBoundary(in pcm16k: Data, from offset: Int, lookaheadSeconds: Double = 0.6) -> Int? {
    let sampleCount = pcm16k.count / 2
    let startSample = max(0, min(offset / 2, sampleCount))
    let lastStart = min(sampleCount - windowSamples, startSample + Int(lookaheadSeconds * 16_000))
    guard lastStart >= startSample else { return nil }
    return pcm16k.withUnsafeBytes { raw -> Int? in
      let samples = raw.bindMemory(to: Int16.self)
      var start = startSample
      while start <= lastStart {
        var sumSquares = 0.0
        for index in start..<(start + windowSamples) {
          let value = Double(Int16(littleEndian: samples[index]))
          sumSquares += value * value
        }
        if (sumSquares / Double(windowSamples)).squareRoot() < speechRMSThreshold {
          return start * 2
        }
        start += windowSamples
      }
      return nil
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
}
