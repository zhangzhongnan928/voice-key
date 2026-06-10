import AppKit
import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    /// Default: Option+Space.
    static let record = Self("recordHotkey", default: .init(.space, modifiers: [.option]))
}

/// Global hotkey handling: toggle mode (press to start, press again to stop)
/// and push-to-talk (hold to record, release to stop). Esc cancels while
/// recording.
final class HotkeyManager {
    var mode: () -> HotkeyMode = { .toggle }
    var isRecording: () -> Bool = { false }

    var onStart: (() -> Void)?
    var onStop: (() -> Void)?
    var onCancel: (() -> Void)?

    private var globalEscMonitor: Any?
    private var localEscMonitor: Any?

    func activate() {
        KeyboardShortcuts.onKeyDown(for: .record) { [weak self] in
            guard let self else { return }
            switch self.mode() {
            case .toggle:
                self.isRecording() ? self.onStop?() : self.onStart?()
            case .pushToTalk:
                if !self.isRecording() { self.onStart?() }
            }
        }
        KeyboardShortcuts.onKeyUp(for: .record) { [weak self] in
            guard let self else { return }
            if self.mode() == .pushToTalk, self.isRecording() {
                self.onStop?()
            }
        }
    }

    /// Installed only while recording so Esc behaves normally otherwise.
    func installEscMonitor() {
        removeEscMonitor()
        globalEscMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { self?.onCancel?() }
        }
        localEscMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 {
                self?.onCancel?()
                return nil
            }
            return event
        }
    }

    func removeEscMonitor() {
        if let globalEscMonitor { NSEvent.removeMonitor(globalEscMonitor) }
        if let localEscMonitor { NSEvent.removeMonitor(localEscMonitor) }
        globalEscMonitor = nil
        localEscMonitor = nil
    }
}
