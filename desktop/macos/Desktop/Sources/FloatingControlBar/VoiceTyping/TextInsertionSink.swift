import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// Where dictated text lands. The protocol exists so the session's delivery
/// rules are testable without touching the clipboard or whatever app the
/// developer happens to have focused.
protocol TextInsertionSink: AnyObject {
  /// Puts `text` at the caret of the focused app in one step. Returns false
  /// when nothing could be posted, so the caller can fall back to `copy`.
  func paste(_ text: String) -> Bool
  /// Leaves `text` on the clipboard for the user to paste themselves.
  func copy(_ text: String)
  /// Whether the character just before the caret is part of a word — i.e. the
  /// dictation is continuing a line, so it needs a separating space first.
  /// False when there is no caret context to read.
  func caretFollowsWordCharacter() -> Bool
  /// Identifies where a paste would land right now — the frontmost
  /// application. Nil when it cannot be read.
  func focusTarget() -> String?
}

extension TextInsertionSink {
  func caretFollowsWordCharacter() -> Bool { false }
  func focusTarget() -> String? { nil }
}

/// Delivers text the way a paste does: onto the general pasteboard, then one
/// ⌘V into whichever application owns keyboard focus, then the previous
/// clipboard contents back.
///
/// Pasting rather than typing keystrokes is what makes a whole paragraph land
/// at once, in every app: keystroke injection is slow for long text and drops
/// characters in Electron and Terminal first-responders, and a paste is the
/// one insertion every text field already handles. The floating bar is a
/// non-activating panel, so during push-to-talk focus is still the user's own
/// app — the caret they were last in.
final class PasteboardTextInsertionSink: TextInsertionSink {

  /// How long the focused app gets to read the pasteboard before the previous
  /// contents are put back. Apps read it synchronously on ⌘V; the delay only
  /// covers event delivery.
  private static let restoreDelay: TimeInterval = 0.4
  private static let vKeyCode: CGKeyCode = 9
  /// Clipboard managers honour this type by not recording the item, so a
  /// dictation does not pollute the user's clipboard history.
  private static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

  /// A private-state source does not inherit live hardware modifiers. A locked
  /// turn is finished by a chord press, so the user may still be physically
  /// holding Option when the paste is posted; sourced from `.hidSystemState`
  /// that ⌘V would arrive as ⌥⌘V.
  private let source = CGEventSource(stateID: .privateState)

  func paste(_ text: String) -> Bool {
    guard !text.isEmpty else { return false }
    let pasteboard = NSPasteboard.general
    let previous = Self.snapshot(pasteboard)
    pasteboard.clearContents()
    let item = NSPasteboardItem()
    item.setString(text, forType: .string)
    item.setString("", forType: Self.transientType)
    guard pasteboard.writeObjects([item]) else {
      Self.restore(previous, to: pasteboard)
      return false
    }
    guard postCommandV() else {
      Self.restore(previous, to: pasteboard)
      return false
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + Self.restoreDelay) {
      // Only if the dictation is still what is on the clipboard: the user may
      // have copied something of their own in the meantime, and that must win.
      guard pasteboard.string(forType: .string) == text else { return }
      Self.restore(previous, to: pasteboard)
    }
    return true
  }

  func copy(_ text: String) {
    guard !text.isEmpty else { return }
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(text, forType: .string)
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

  private func postCommandV() -> Bool {
    var posted = false
    for isDown in [true, false] {
      guard let event = CGEvent(keyboardEventSource: source, virtualKey: Self.vKeyCode, keyDown: isDown)
      else { continue }
      event.flags = .maskCommand
      event.post(tap: .cghidEventTap)
      posted = true
    }
    return posted
  }

  /// Every item's every representation, so a copied image or rich text is put
  /// back exactly as it was. An item already on a pasteboard cannot be written
  /// to it again, so the data is copied out rather than the items kept.
  private static func snapshot(_ pasteboard: NSPasteboard) -> [[NSPasteboard.PasteboardType: Data]] {
    (pasteboard.pasteboardItems ?? []).map { item in
      var representations: [NSPasteboard.PasteboardType: Data] = [:]
      for type in item.types {
        if let data = item.data(forType: type) { representations[type] = data }
      }
      return representations
    }
  }

  private static func restore(_ items: [[NSPasteboard.PasteboardType: Data]], to pasteboard: NSPasteboard) {
    pasteboard.clearContents()
    let restored = items.compactMap { representations -> NSPasteboardItem? in
      guard !representations.isEmpty else { return nil }
      let item = NSPasteboardItem()
      for (type, data) in representations { item.setData(data, forType: type) }
      return item
    }
    if !restored.isEmpty { pasteboard.writeObjects(restored) }
  }
}
