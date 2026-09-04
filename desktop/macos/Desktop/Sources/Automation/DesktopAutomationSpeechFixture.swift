import Foundation

/// Synthesizes a spoken fixture with the system speech synthesizer so an
/// automation flow can drive a push-to-talk hold without shipping audio
/// files or asking a human to speak. Non-production bridge only; the output
/// is raw s16le 16 kHz mono, the format the PTT chunk path consumes.
enum DesktopAutomationSpeechFixture {

  enum SynthesisError: Error {
    case sayFailed(Int32)
    case malformedWave
  }

  /// `say` writes a RIFF file that carries a `JUNK` chunk before `fmt `, so
  /// the header is not 44 bytes; the `data` chunk is located by walking the
  /// chunks rather than by a fixed offset.
  static func pcm16k(saying text: String, voice: String = "Samantha", rate: Int = 185) throws -> Data {
    let output = FileManager.default.temporaryDirectory
      .appendingPathComponent("omi-speech-fixture-\(UUID().uuidString).wav")
    defer { try? FileManager.default.removeItem(at: output) }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
    process.arguments = [
      "-v", voice, "-r", "\(rate)", "-o", output.path, "--data-format=LEI16@16000", text,
    ]
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { throw SynthesisError.sayFailed(process.terminationStatus) }
    return try dataChunk(ofWave: Data(contentsOf: output))
  }

  static func dataChunk(ofWave wave: Data) throws -> Data {
    guard wave.count >= 12, wave[0..<4] == Data("RIFF".utf8), wave[8..<12] == Data("WAVE".utf8) else {
      throw SynthesisError.malformedWave
    }
    var offset = 12
    while offset + 8 <= wave.count {
      let id = wave[offset..<(offset + 4)]
      let size = Int(wave[(offset + 4)..<(offset + 8)].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) })
      let body = offset + 8
      if id == Data("data".utf8) {
        let end = min(body + size, wave.count)
        return Data(wave[body..<end])
      }
      offset = body + size + (size & 1)
    }
    throw SynthesisError.malformedWave
  }
}
