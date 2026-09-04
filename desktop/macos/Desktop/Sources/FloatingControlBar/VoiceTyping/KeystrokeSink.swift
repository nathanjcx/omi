import AppKit
import ApplicationServices
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
  /// Whether the character just before the caret is part of a word — i.e. the
  /// dictation is continuing a line, so it needs a separating space first.
  /// False when there is no caret context to read.
  func caretFollowsWordCharacter() -> Bool
  /// Identifies where keystrokes would land right now — the frontmost
  /// application. Nil when it cannot be read.
  func focusTarget() -> String?
}

extension KeystrokeSink {
  func caretFollowsWordCharacter() -> Bool { false }
  func focusTarget() -> String? { nil }
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

  func focusTarget() -> String? {
    guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
    return "\(app.processIdentifier):\(app.bundleIdentifier ?? "")"
  }

  /// Reads one character behind the caret through Accessibility. A second
  /// dictation into the same line landed flush against the first ("voiceI
  /// think") because nothing knew what the caret was sitting after. Only the
  /// one character is fetched (`AXStringForRange`), never the document.
  func caretFollowsWordCharacter() -> Bool {
    var focusedRef: CFTypeRef?
    guard
      AXUIElementCopyAttributeValue(
        AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
      let focusedRef, CFGetTypeID(focusedRef) == AXUIElementGetTypeID()
    else { return false }
    // swiftlint:disable:next force_cast
    let element = focusedRef as! AXUIElement
    var rangeRef: CFTypeRef?
    guard
      AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
      let rangeRef, CFGetTypeID(rangeRef) == AXValueGetTypeID()
    else { return false }
    var selection = CFRange()
    // swiftlint:disable:next force_cast
    guard AXValueGetValue(rangeRef as! AXValue, .cfRange, &selection), selection.location > 0 else { return false }
    var previous = CFRange(location: selection.location - 1, length: 1)
    guard let parameter = AXValueCreate(.cfRange, &previous) else { return false }
    var textRef: CFTypeRef?
    guard
      AXUIElementCopyParameterizedAttributeValue(
        element, kAXStringForRangeParameterizedAttribute as CFString, parameter, &textRef) == .success,
      let text = textRef as? String, let character = text.last
    else { return false }
    return !character.isWhitespace && !character.isNewline
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
