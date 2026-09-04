import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// How a finished dictation reached the focused app.
enum VoiceTypeInsertion: String, Equatable {
  /// Put on the pasteboard and pasted with ⌘V — one operation, whole text.
  case pasted
  /// Synthesized character by character, because the pasteboard was refused.
  case typed
  case failed
}

/// Where a finished dictation lands. The protocol exists so the session's
/// delivery decisions are testable without posting real events into whatever
/// app the developer happens to have focused.
@MainActor
protocol VoiceTypeTextInserter: AnyObject {
  /// Delivers `text` in one operation, at the caret.
  func insert(_ text: String) -> VoiceTypeInsertion
  /// Whether the character just before the caret is part of a word — i.e. the
  /// dictation is continuing a line, so it needs a separating space first.
  /// False when there is no caret context to read.
  func caretFollowsWordCharacter() -> Bool
  /// Bundle identifier of the application that would receive the text right
  /// now. Nil when it cannot be read.
  func frontmostBundleIdentifier() -> String?
}

/// Pastes the dictation into whichever application owns keyboard focus.
///
/// Pasting rather than typing is what makes delivery instant and atomic, and it
/// is only available now that nothing is delivered until the utterance is
/// complete. Synthesizing a paragraph as keystrokes takes one event per handful
/// of characters and slow first responders (Electron, Terminal) drop the tail of
/// a long insertion; the user also watches the sentence crawl in. A pasteboard
/// write plus one ⌘V is a single operation whose cost does not grow with the
/// length of what was said.
///
/// The user's pasteboard is saved and put back. That is not a nicety: dictation
/// is used mid-task, and silently eating whatever the user had copied would be
/// its own bug.
@MainActor
final class PasteboardTextInserter: VoiceTypeTextInserter {

  /// `kVK_ANSI_V`.
  private static let vKeyCode: CGKeyCode = 9
  private static let deleteKeyCode: CGKeyCode = 51
  /// Unicode payload per event on the fallback path. CoreGraphics accepts
  /// longer strings, but short chunks keep slow first-responders from dropping
  /// the tail of a long insertion.
  private static let chunkUTF16 = 16
  /// How long the pasted text is left on the pasteboard before the user's own
  /// contents go back. The target app reads the pasteboard asynchronously after
  /// the ⌘V it was sent, so restoring immediately races that read and pastes
  /// the *old* clipboard into the document.
  private static let restoreDelay: TimeInterval = 0.6

  /// A private-state source does not inherit live hardware modifiers. That is
  /// load-bearing here: push-to-talk is a modifier-only chord by default, so the
  /// user is *physically holding* Option (or Fn, or right Command) at the moment
  /// this posts. Sourced from `.hidSystemState`, the ⌘V would arrive as ⌥⌘V and
  /// the fallback path's every "n" as ⌥n.
  private let source = CGEventSource(stateID: .privateState)

  func insert(_ text: String) -> VoiceTypeInsertion {
    guard !text.isEmpty else { return .failed }
    let pasteboard = NSPasteboard.general
    let saved = Self.snapshot(pasteboard)
    pasteboard.clearContents()
    guard pasteboard.setString(text, forType: .string) else {
      Self.restore(saved)
      guard typeOut(text) else { return .failed }
      return .typed
    }
    post(virtualKey: Self.vKeyCode, flags: .maskCommand, unicode: nil)
    Task { @MainActor in
      try? await Task.sleep(nanoseconds: UInt64(Self.restoreDelay * 1_000_000_000))
      Self.restore(saved)
    }
    return .pasted
  }

  func frontmostBundleIdentifier() -> String? {
    NSWorkspace.shared.frontmostApplication?.bundleIdentifier
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
    // Type-checked above; an unsafe downcast avoids a force cast on a CF handle,
    // which the SwiftLint baseline ratchet rejects.
    let element = unsafeDowncast(focusedRef, to: AXUIElement.self)
    var rangeRef: CFTypeRef?
    guard
      AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
      let rangeRef, CFGetTypeID(rangeRef) == AXValueGetTypeID()
    else { return false }
    let rangeValue = unsafeDowncast(rangeRef, to: AXValue.self)
    var selection = CFRange()
    guard AXValueGetValue(rangeValue, .cfRange, &selection), selection.location > 0 else { return false }
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

  /// The fallback when the pasteboard refuses the write. Rare, and worth having:
  /// a dictation the user already spoke should not be lost to a pasteboard that
  /// another process has locked.
  private func typeOut(_ text: String) -> Bool {
    guard source != nil else { return false }
    var chunk: [UniChar] = []
    chunk.reserveCapacity(Self.chunkUTF16)
    for unit in text.utf16 {
      chunk.append(unit)
      if chunk.count == Self.chunkUTF16 {
        post(virtualKey: 0, flags: [], unicode: chunk)
        chunk.removeAll(keepingCapacity: true)
      }
    }
    if !chunk.isEmpty {
      post(virtualKey: 0, flags: [], unicode: chunk)
    }
    return true
  }

  private func post(virtualKey: CGKeyCode, flags: CGEventFlags, unicode: [UniChar]?) {
    for isDown in [true, false] {
      guard let event = CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: isDown)
      else { continue }
      event.flags = flags
      if var unicode, !unicode.isEmpty {
        event.keyboardSetUnicodeString(stringLength: unicode.count, unicodeString: &unicode)
      }
      event.post(tap: .cghidEventTap)
    }
  }

  /// Every type on every item, as plain data. Deliberately not the
  /// `NSPasteboardItem`s themselves: those become invalid the moment the
  /// pasteboard is cleared, so keeping them would restore nothing.
  private static func snapshot(_ pasteboard: NSPasteboard) -> [[String: Data]] {
    (pasteboard.pasteboardItems ?? []).map { item in
      var payload: [String: Data] = [:]
      for type in item.types {
        if let data = item.data(forType: type) { payload[type.rawValue] = data }
      }
      return payload
    }
  }

  private static func restore(_ snapshot: [[String: Data]]) {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    guard !snapshot.isEmpty else { return }
    let items = snapshot.map { payload -> NSPasteboardItem in
      let item = NSPasteboardItem()
      for (raw, data) in payload {
        item.setData(data, forType: NSPasteboard.PasteboardType(raw))
      }
      return item
    }
    _ = pasteboard.writeObjects(items)
  }
}
