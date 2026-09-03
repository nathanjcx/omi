import CoreGraphics
import Foundation

/// Where dictated text lands. The protocol exists so the session's edit
/// sequencing is testable without posting real events into whatever app the
/// developer happens to have focused.
protocol KeystrokeSink: AnyObject {
  /// Deletes `count` characters behind the caret.
  func deleteBackward(_ count: Int)
  /// Inserts `text` at the caret.
  func insert(_ text: String)
}

/// Posts synthesized keyboard input to whichever application owns keyboard
/// focus. The floating bar is a non-activating panel, so during push-to-talk
/// that is still the user's own app — the caret they were last in.
final class CGEventKeystrokeSink: KeystrokeSink {

  /// Unicode payload per event. CoreGraphics accepts longer strings, but short
  /// chunks keep slow first-responders (Electron, Terminal) from dropping the
  /// tail of a long insertion.
  private static let chunkUTF16 = 16
  private static let deleteKeyCode: CGKeyCode = 51

  /// A private-state source does not inherit live hardware modifiers. That is
  /// load-bearing here: push-to-talk is a modifier-only chord by default, so the
  /// user is *physically holding* Option (or Fn, or right Command) while these
  /// events are posted. Sourced from `.hidSystemState`, every dictated "n" would
  /// arrive as ⌥n. Flags are also cleared explicitly per event.
  private let source = CGEventSource(stateID: .privateState)

  func deleteBackward(_ count: Int) {
    guard count > 0 else { return }
    for _ in 0..<count {
      post(virtualKey: Self.deleteKeyCode, unicode: nil)
    }
  }

  func insert(_ text: String) {
    guard !text.isEmpty else { return }
    var chunk: [UniChar] = []
    chunk.reserveCapacity(Self.chunkUTF16)
    for unit in text.utf16 {
      chunk.append(unit)
      if chunk.count == Self.chunkUTF16 {
        post(virtualKey: 0, unicode: chunk)
        chunk.removeAll(keepingCapacity: true)
      }
    }
    if !chunk.isEmpty {
      post(virtualKey: 0, unicode: chunk)
    }
  }

  private func post(virtualKey: CGKeyCode, unicode: [UniChar]?) {
    for isDown in [true, false] {
      guard let event = CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: isDown)
      else { continue }
      event.flags = []
      if var unicode, !unicode.isEmpty {
        event.keyboardSetUnicodeString(stringLength: unicode.count, unicodeString: &unicode)
      }
      event.post(tap: .cghidEventTap)
    }
  }
}
