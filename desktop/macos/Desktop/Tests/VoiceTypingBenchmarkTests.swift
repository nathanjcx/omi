import Foundation
import XCTest

@testable import Omi_Computer

/// Accuracy and speed benchmark for voice typing, outside the app.
///
/// Drives the production pipeline the way `PushToTalkManager` does — the
/// on-device recognizer (`PTTLanguageIdentifier`), the decode window, the
/// stabilizer, the planner and the session — with speech synthesized by the
/// system voice, so it needs no microphone, no Accessibility grant, no backend
/// and no running app. Fifty holds across short commands, numbers, names,
/// punctuation, long paragraphs, several voices and rates.
///
/// Opt-in: it needs `say`, the Parakeet model on disk and several minutes, so
/// it is skipped unless `OMI_VOICE_TYPING_BENCH=1`. CI stays hermetic. Run:
///
///     OMI_VOICE_TYPING_BENCH=1 DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
///       xcrun swift test --package-path Desktop --filter VoiceTypingBenchmark
///
/// Writes a JSON report next to the console table (`OMI_VOICE_TYPING_BENCH_REPORT`
/// or the temporary directory) so two runs can be compared field by field.
// omi-test-quality: wall-clock-wait -- the benchmark measures the real recognizer's latency; it is opt-in and never runs in CI
@MainActor
final class VoiceTypingBenchmarkTests: XCTestCase {

  // MARK: - Cases

  struct Case {
    let id: String
    let category: String
    let wake: String
    let payload: String
    var voice = "Samantha"
    var rate = 185
    var spoken: String { wake + " " + payload }
  }

  static let cases: [Case] = {
    var c: [Case] = []
    func add(_ cat: String, _ wake: String, _ payload: String, voice: String = "Samantha", rate: Int = 185) {
      c.append(
        Case(
          id: String(format: "%02d", c.count + 1), category: cat, wake: wake, payload: payload, voice: voice, rate: rate
        ))
    }
    // Short commands and replies.
    add("short", "Type.", "Sounds good, see you at three.")
    add("short", "Type,", "On my way.")
    add("short", "Type.", "Can we move this to Thursday?")
    add("short", "Type this:", "Approved, please proceed.")
    add("short", "Type out", "Thanks for the update, I will take a look tonight.")
    add("short", "Type.", "No, that is not what I meant.")
    add("short", "Type.", "Yes.", voice: "Daniel")
    add("short", "Type.", "Let me check and get back to you.", voice: "Karen")
    add("short", "Type.", "Running five minutes late.", rate: 220)
    add("short", "Type.", "Okay, done.", rate: 150)
    // Reported live: typed as "Hado IClear Claud Code Prompt Entry".
    add("short", "Type.", "How do I clear Claude Code prompt entry", voice: "Daniel")
    // Everyday sentences.
    add(
      "everyday", "Type.",
      "I think we should ship the smaller change first and measure before we commit to the redesign.")
    add("everyday", "Type.", "The meeting ran long, so I did not get to the second half of the agenda.")
    add("everyday", "Type.", "Could you send me the link to the shared folder when you get a chance?")
    add("everyday", "Type.", "My flight lands at nine, and I should be at the office by eleven.", voice: "Moira")
    add(
      "everyday", "Type.", "Let us keep the tone friendly but direct, and avoid making promises about dates.",
      voice: "Daniel")
    add("everyday", "Type.", "It works on my machine, which is exactly what worries me.", voice: "Tessa")
    add("everyday", "Type.", "We are out of coffee again, and the printer is still jammed.", rate: 215)
    add("everyday", "Type.", "I will bring the slides, you bring the demo hardware.", rate: 160)
    add("everyday", "Type.", "Honestly the first draft was better than the second one.", voice: "Karen")
    add("everyday", "Type.", "Please remind me to call the dentist tomorrow morning.")
    // Numbers, dates, addresses.
    add("numbers", "Type.", "The invoice total is four hundred and twenty dollars, due on the fifteenth of October.")
    add("numbers", "Type.", "Call me at five five five, zero one nine two.")
    add("numbers", "Type.", "The apartment is on the third floor, unit twelve B.")
    add("numbers", "Type.", "We sold two thousand three hundred units in the first quarter.")
    add("numbers", "Type.", "Version two point four point one fixes the crash on startup.", voice: "Daniel")
    add("numbers", "Type.", "The temperature dropped to minus eight overnight.")
    add("numbers", "Type.", "Half of the twenty participants finished in under ten minutes.", voice: "Moira")
    add("numbers", "Type.", "Set the timer for forty five seconds.", rate: 210)
    // Names and jargon.
    add("names", "Type.", "Ask Priya and Marcus whether the Kubernetes rollout is still on for Friday.")
    add("names", "Type.", "The Bluetooth firmware on the Omi device needs a reset after pairing.")
    add("names", "Type.", "Loop in Nathan from the hardware team before we change the connector.")
    add("names", "Type.", "The Postgres migration touched the users table and the sessions index.", voice: "Daniel")
    add("names", "Type.", "Elena said the Figma file is ready for review.", voice: "Karen")
    add("names", "Type.", "Push the branch, open the pull request, and tag Alejandro as a reviewer.")
    add("names", "Type.", "The OAuth token expires after an hour, so refresh it in the background.", voice: "Tessa")
    add("names", "Type.", "SwiftUI previews keep crashing when the view model is a main actor.", voice: "Moira")
    // Punctuation-heavy.
    add("punctuation", "Type.", "Wait, really? That changes everything!")
    add("punctuation", "Type.", "First, gather the logs; second, reproduce the bug; third, write the test.")
    add("punctuation", "Type.", "The customer wrote: it stopped working after the update.", voice: "Daniel")
    add("punctuation", "Type.", "Do not merge yet. We still need sign off from design.")
    add("punctuation", "Type.", "Three things: budget, timeline, and who owns the launch.", voice: "Karen")
    // Long holds.
    let long1 =
      "The quarterly report is due on Friday afternoon. Please send the draft to the design team before noon so they have time to review it. We should also schedule a follow up meeting with the hardware vendor next week. The new firmware build fixed the Bluetooth reconnection issue on most devices, but a few users still report that the battery indicator is inaccurate after a full charge. I think we need better telemetry around the charging state machine before we call it done."
    let long2 =
      "On the marketing side, the landing page copy needs one more pass before launch. The headline is strong, but the second paragraph repeats the first one almost word for word, so I would cut it down to two sentences and move the pricing link higher on the page. Also, the support inbox has about forty open conversations from the weekend, mostly questions about shipping times to Europe and Canada. One help center article and a canned reply would clear most of them."
    let long3 =
      "Here is what I learned from the interviews this week. People do not mind waiting a second for the answer if they trust it, but they hate correcting the same word twice. Nobody used the keyboard shortcut we spent a sprint on, and three of the five participants tried to talk to the app before they found the button. The most requested feature, by far, was dictating directly into whatever window they already had open."
    let long4 =
      "Recipe notes for Sunday. Toast the cumin and coriander seeds in a dry pan until fragrant, then grind them with a pinch of salt. Soften the onions slowly, at least fifteen minutes, before adding the garlic and ginger. Add the tomatoes, the spices, and a cup of water, and let it simmer while the rice cooks. Finish with lemon juice and a handful of chopped cilantro, and taste for salt before serving."
    add("long", "Type.", long1)
    add("long", "Type.", long2, voice: "Daniel")
    add("long", "Type.", long3, voice: "Karen")
    add("long", "Type.", long4, voice: "Moira", rate: 170)
    add("long", "Type.", long1 + " " + long2, rate: 200)
    add("long", "Type.", long3 + " " + long4, voice: "Tessa")
    add("long", "Type out", long2 + " " + long1, voice: "Daniel", rate: 175)
    add("long", "Type.", long4 + " " + long3 + " " + long2, rate: 190)
    precondition(c.count == 50, "the benchmark is fifty holds; got \(c.count)")
    return c
  }()

  // MARK: - Pipeline driver (mirrors PushToTalkManager's on-device path)

  private final class RecordingSink: KeystrokeSink {
    private(set) var typed = ""
    private(set) var deletions = 0
    private(set) var insertions = 0
    func deleteBackward(_ count: Int) {
      guard count > 0 else { return }
      deletions += count
      typed.removeLast(min(count, typed.count))
    }
    func insert(_ text: String) {
      insertions += text.count
      typed += text
    }
  }

  struct Outcome: Codable {
    let id: String
    let category: String
    let voice: String
    let rate: Int
    let audioSeconds: Double
    let heardWakeWord: Bool
    let claimed: Bool
    let typed: String
    let expected: String
    let wordErrorRate: Double
    let firstCharAudioSeconds: Double?
    let probes: Int
    let meanProbeMs: Double
    let maxProbeMs: Double
    let decodeSecondsPerAudioSecond: Double
    let commits: Int
    let deletedChars: Int
    let insertedChars: Int
  }

  private static let chunkBytes = 3_200  // 100 ms
  private static let probeIntervalBytes = 6_400  // 200 ms, PushToTalkManager.voiceTypingProbeInterval

  private func run(_ c: Case, pcm: Data) async -> Outcome {
    let sink = RecordingSink()
    let session = VoiceTypeSession(sink: sink, isAccessibilityTrusted: { true })
    var window = VoiceTypeDecodeWindow()
    session.begin()

    var sinceProbe = 0
    var lastTail = ""
    var probes = 0
    var probeMs: [Double] = []
    var commits = 0
    var firstChar: Double?
    var offset = 0
    let total = pcm.count

    while offset < total {
      let end = min(offset + Self.chunkBytes, total)
      let chunk = pcm.subdata(in: offset..<end)
      offset = end
      window.append(chunk)
      sinceProbe += chunk.count
      guard sinceProbe >= Self.probeIntervalBytes else { continue }
      sinceProbe = 0
      let pending = window.pendingAudio
      let audio = window.hasCommitted ? pending : VoiceTypeAudioTrim.trimmingLeadingSilence(pending)
      guard audio.count >= 12_800 else { continue }
      let started = Date()
      let tail = await PTTLanguageIdentifier.shared.transcribe(pcm16k: audio)
      probeMs.append(Date().timeIntervalSince(started) * 1000)
      probes += 1
      guard let tail else { continue }
      let stable = tail == lastTail
      lastTail = tail
      let committed = window.commitIfReady(
        tail: tail,
        endsQuiet: VoiceTypeAudioTrim.endsQuiet(audio, seconds: PushToTalkManager.voiceTypingLocalCommitPause),
        tailIsStable: stable)
      if committed {
        commits += 1
        lastTail = ""
      }
      let localTail = window.pendingAudio.isEmpty ? "" : tail
      session.update(transcript: window.transcript(tail: localTail))
      if firstChar == nil, !sink.typed.isEmpty { firstChar = Double(offset / 2) / 16_000 }
    }

    // Key-up flush.
    let remaining = VoiceTypeAudioTrim.trimmingLeadingSilence(window.pendingAudio)
    let decoded =
      VoiceTypeAudioTrim.speechBytes(in: remaining) < VoiceTypeDecodeWindow.minimumDecodableSpeechBytes
      ? nil : await PTTLanguageIdentifier.shared.transcribe(pcm16k: remaining)
    let heard = session.heardWakeWord
    let completion = session.finish(transcript: window.transcript(tail: decoded ?? ""))
    let claimed: Bool
    if case .typed = completion { claimed = true } else { claimed = false }

    let audioSeconds = Double(total / 2) / 16_000
    let decodeSeconds = probeMs.reduce(0, +) / 1000
    return Outcome(
      id: c.id, category: c.category, voice: c.voice, rate: c.rate, audioSeconds: audioSeconds,
      heardWakeWord: heard, claimed: claimed, typed: sink.typed, expected: c.payload,
      wordErrorRate: Self.wordErrorRate(expected: c.payload, actual: sink.typed),
      firstCharAudioSeconds: firstChar, probes: probes,
      meanProbeMs: probeMs.isEmpty ? 0 : probeMs.reduce(0, +) / Double(probeMs.count),
      maxProbeMs: probeMs.max() ?? 0,
      decodeSecondsPerAudioSecond: audioSeconds > 0 ? decodeSeconds / audioSeconds : 0,
      commits: commits, deletedChars: sink.deletions, insertedChars: sink.insertions)
  }

  // MARK: - Scoring

  static func normalizedWords(_ text: String) -> [String] {
    text.lowercased()
      .replacingOccurrences(of: "-", with: " ")
      .split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "'" })
      .map { spellOutNumber(String($0)) }
      .flatMap { $0.split(separator: " ").map(String.init) }
  }

  /// Recognizers write "forty five" as "45"; the script says the words. Both
  /// sides are compared as words so a digit is not counted as a misspelling.
  static func spellOutNumber(_ token: String) -> String {
    guard let n = Int(token), n >= 0, n < 10_000 else { return token }
    let ones = [
      "zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "eleven", "twelve",
      "thirteen", "fourteen", "fifteen", "sixteen", "seventeen", "eighteen", "nineteen",
    ]
    let tens = ["", "", "twenty", "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety"]
    func below100(_ v: Int) -> String {
      if v < 20 { return ones[v] }
      return v % 10 == 0 ? tens[v / 10] : tens[v / 10] + " " + ones[v % 10]
    }
    if n < 100 { return below100(n) }
    if n < 1000 {
      let rest = n % 100
      return ones[n / 100] + " hundred" + (rest == 0 ? "" : " " + below100(rest))
    }
    let rest = n % 1000
    return below100(n / 1000) + " thousand" + (rest == 0 ? "" : " " + spellOutNumber(String(rest)))
  }

  static func wordErrorRate(expected: String, actual: String) -> Double {
    let e = normalizedWords(expected)
    let a = normalizedWords(actual)
    guard !e.isEmpty else { return a.isEmpty ? 0 : 1 }
    var prev = Array(0...a.count)
    for i in 1...e.count {
      var cur = [i] + Array(repeating: 0, count: a.count)
      for j in stride(from: 1, through: a.count, by: 1) where a.count > 0 {
        let cost = e[i - 1] == a[j - 1] ? 0 : 1
        cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost)
      }
      prev = cur
    }
    return Double(prev[a.count]) / Double(e.count)
  }

  // MARK: - Fixtures

  private static func fixtureURL(for c: Case) -> URL {
    let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("OmiDesktop/voice-typing-bench", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let key = "\(c.voice)-\(c.rate)-\(c.spoken)".utf8.reduce(into: UInt64(1_469_598_103_934_665_603)) { hash, byte in
      hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211
    }
    return dir.appendingPathComponent("\(c.id)-\(String(key, radix: 16)).pcm")
  }

  private static func pcm(for c: Case) throws -> Data {
    let url = fixtureURL(for: c)
    if let cached = try? Data(contentsOf: url), !cached.isEmpty { return cached }
    let data = try DesktopAutomationSpeechFixture.pcm16k(saying: c.spoken, voice: c.voice, rate: c.rate)
    try data.write(to: url)
    return data
  }

  // MARK: - The benchmark

  func testFiftyHoldsAccuracyAndSpeed() async throws {
    try XCTSkipUnless(
      ProcessInfo.processInfo.environment["OMI_VOICE_TYPING_BENCH"] == "1",
      "opt-in benchmark: needs `say`, the on-device model and several minutes")
    await PTTLanguageIdentifier.shared.prewarm()

    var outcomes: [Outcome] = []
    for c in Self.cases {
      let pcm = try Self.pcm(for: c)
      let outcome = await run(c, pcm: pcm)
      outcomes.append(outcome)
      let first = outcome.firstCharAudioSeconds.map { String(format: "%.1fs", $0) } ?? "—"
      print(
        String(
          format:
            "%@ %-11@ %-8@ %3d  %5.1fs  wer=%5.1f%%  first=%@  probe=%3.0fms/%3.0fms  rtf=%.2f  commits=%d  del=%d%@",
          outcome.id, outcome.category, outcome.voice, outcome.rate, outcome.audioSeconds,
          outcome.wordErrorRate * 100, first, outcome.meanProbeMs, outcome.maxProbeMs,
          outcome.decodeSecondsPerAudioSecond, outcome.commits, outcome.deletedChars,
          outcome.claimed ? "" : "  NOT CLAIMED"))
      if outcome.wordErrorRate > 0 {
        print("      expected: \(outcome.expected)")
        print("      typed:    \(outcome.typed)")
      }
    }

    let claimed = outcomes.filter(\.claimed).count
    let meanWER = outcomes.map(\.wordErrorRate).reduce(0, +) / Double(outcomes.count)
    let totalAudio = outcomes.map(\.audioSeconds).reduce(0, +)
    let meanRTF = outcomes.map { $0.decodeSecondsPerAudioSecond * $0.audioSeconds }.reduce(0, +) / totalAudio
    let firsts = outcomes.compactMap(\.firstCharAudioSeconds)
    let meanFirst = firsts.isEmpty ? 0 : firsts.reduce(0, +) / Double(firsts.count)
    let byCategory = Dictionary(grouping: outcomes, by: \.category).mapValues { group in
      group.map(\.wordErrorRate).reduce(0, +) / Double(group.count)
    }
    print("")
    print(
      String(
        format: "SUMMARY claimed=%d/%d meanWER=%.1f%% meanFirstChar=%.2fs meanRTF=%.3f totalAudio=%.0fs", claimed,
        outcomes.count, meanWER * 100, meanFirst, meanRTF, totalAudio))
    for (cat, wer) in byCategory.sorted(by: { $0.key < $1.key }) {
      print(String(format: "  %-12@ wer=%.1f%%", cat, wer * 100))
    }

    let reportPath =
      ProcessInfo.processInfo.environment["OMI_VOICE_TYPING_BENCH_REPORT"]
      ?? FileManager.default.temporaryDirectory.appendingPathComponent("voice-typing-bench.json").path
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(outcomes).write(to: URL(fileURLWithPath: reportPath))
    print("report: \(reportPath)")

    XCTAssertEqual(claimed, outcomes.count, "every hold that opens with the wake word must be claimed")
  }
}
