import AppKit
import Carbon.HIToolbox
import Foundation

enum InsertionMethod: Equatable {
    case paste
    case type
    case clipboardOnly   // secure input active: leave text in clipboard
}

/// Pure decision logic, unit-testable without posting events.
enum InsertionPlanner {
    static func method(strategy: InsertionStrategy, secureInputEnabled: Bool) -> InsertionMethod {
        if secureInputEnabled { return .clipboardOnly }
        switch strategy {
        case .paste: return .paste
        case .type: return .type
        }
    }
}

enum InsertionOutcome: Equatable {
    case inserted(InsertionMethod)
    /// Text was placed in the clipboard instead of inserted; the reason is
    /// user-facing.
    case clipboardFallback(reason: String)
}

/// Puts transcript text into the focused field. Guarantee: on ANY failure the
/// transcript still ends up in the clipboard (F6).
final class Inserter {
    /// Injectable for the secure-input unit test.
    var secureInputDetector: () -> Bool = { IsSecureEventInputEnabled() }
    /// Injectable accessibility check.
    var accessibilityTrusted: () -> Bool = { AXIsProcessTrusted() }

    func insert(_ text: String, strategy: InsertionStrategy, clipboardRestoreDelayMs: Int) -> InsertionOutcome {
        if secureInputDetector() {
            setClipboard(text)
            Log.insert.info("secure input active; transcript left in clipboard")
            return .clipboardFallback(reason: "A password field is focused — transcript copied to the clipboard instead.")
        }
        guard accessibilityTrusted() else {
            setClipboard(text)
            Log.insert.warning("accessibility not granted; transcript left in clipboard")
            return .clipboardFallback(reason: "Accessibility permission is missing — transcript copied to the clipboard. Grant it in System Settings > Privacy & Security > Accessibility.")
        }

        switch InsertionPlanner.method(strategy: strategy, secureInputEnabled: false) {
        case .paste:
            return pasteInsert(text, restoreDelayMs: clipboardRestoreDelayMs)
        case .type:
            return typeInsert(text)
        case .clipboardOnly:
            setClipboard(text)
            return .clipboardFallback(reason: "Transcript copied to the clipboard.")
        }
    }

    // MARK: Strategy A: clipboard + synthetic Cmd+V

    private func pasteInsert(_ text: String, restoreDelayMs: Int) -> InsertionOutcome {
        let pasteboard = NSPasteboard.general
        let savedString = pasteboard.string(forType: .string)

        setClipboard(text)

        guard postCmdV() else {
            // Leave the transcript in the clipboard (do not restore) so the
            // user can paste manually.
            Log.insert.error("Cmd+V synthesis failed; transcript left in clipboard")
            return .clipboardFallback(reason: "Could not synthesize paste — transcript copied to the clipboard.")
        }

        // Restore the previous clipboard after the target app has consumed
        // the paste.
        if let savedString {
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(max(0, restoreDelayMs))) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(savedString, forType: .string)
            }
        }
        return .inserted(.paste)
    }

    private func postCmdV() -> Bool {
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let keyDown = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false)
        else { return false }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        return true
    }

    // MARK: Strategy B: typing simulation

    private func typeInsert(_ text: String) -> InsertionOutcome {
        guard let source = CGEventSource(stateID: .combinedSessionState) else {
            setClipboard(text)
            return .clipboardFallback(reason: "Could not create event source — transcript copied to the clipboard.")
        }
        // CGEventKeyboardSetUnicodeString handles a limited payload per
        // event; send in small chunks with a tiny gap so slow apps keep up.
        let chunkSize = 20
        let characters = Array(text.utf16)
        var index = 0
        while index < characters.count {
            let chunk = Array(characters[index..<min(index + chunkSize, characters.count)])
            guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
            else {
                setClipboard(text)
                return .clipboardFallback(reason: "Typing simulation failed — transcript copied to the clipboard.")
            }
            chunk.withUnsafeBufferPointer { pointer in
                keyDown.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: pointer.baseAddress)
            }
            keyDown.post(tap: .cghidEventTap)
            keyUp.post(tap: .cghidEventTap)
            index += chunkSize
            usleep(8_000)
        }
        return .inserted(.type)
    }

    // MARK: Clipboard

    func setClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
