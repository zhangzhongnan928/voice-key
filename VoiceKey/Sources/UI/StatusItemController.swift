import AppKit

/// Menu bar item: icon reflects app state, menu per F10.
final class StatusItemController: NSObject, NSMenuDelegate {
    enum IconState {
        case idle, recording, uploading, error

        var symbolName: String {
            switch self {
            case .idle: return "mic"
            case .recording: return "record.circle.fill"
            case .uploading: return "arrow.up.circle"
            case .error: return "exclamationmark.triangle"
            }
        }
    }

    private let statusItem: NSStatusItem
    private let menu = NSMenu()

    /// Anchor for the History popover.
    var button: NSStatusBarButton? { statusItem.button }

    var onToggleRecording: (() -> Void)?
    var onOpenHistory: (() -> Void)?
    var onOpenSettings: (() -> Void)?
    var onCopyLastTranscript: (() -> Void)?

    /// Live data providers, queried each time the menu opens.
    var isRecordingProvider: () -> Bool = { false }
    var lastTranscriptProvider: () -> String? = { nil }
    var monthlyCostProvider: () -> Double = { 0 }

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        setIcon(.idle)
        menu.delegate = self
        statusItem.menu = menu
    }

    func setIcon(_ state: IconState) {
        guard let button = statusItem.button else { return }
        let image = NSImage(systemSymbolName: state.symbolName, accessibilityDescription: "VoiceKey")
        image?.isTemplate = (state == .idle || state == .uploading)
        button.image = image
    }

    // Rebuild the menu lazily so cost/last-transcript are current.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let recordTitle = isRecordingProvider() ? "Stop Recording" : "Start Recording"
        let record = NSMenuItem(title: recordTitle, action: #selector(toggleRecording), keyEquivalent: "")
        record.target = self
        menu.addItem(record)

        menu.addItem(.separator())

        if let last = lastTranscriptProvider(), !last.isEmpty {
            let preview = String(last.prefix(50)) + (last.count > 50 ? "…" : "")
            let item = NSMenuItem(title: "“\(preview)”", action: #selector(copyLast), keyEquivalent: "")
            item.target = self
            item.toolTip = "Click to copy the last transcript"
            menu.addItem(item)
        }

        let cost = NSMenuItem(
            title: String(format: "This month: $%.2f", monthlyCostProvider()),
            action: nil,
            keyEquivalent: ""
        )
        cost.isEnabled = false
        // CR-6
        cost.toolTip = "This device only (estimate). Authoritative usage: OpenAI dashboard."
        menu.addItem(cost)

        menu.addItem(.separator())

        let history = NSMenuItem(title: "History…", action: #selector(openHistory), keyEquivalent: "h")
        history.target = self
        menu.addItem(history)

        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit VoiceKey", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    @objc private func toggleRecording() { onToggleRecording?() }
    @objc private func openHistory() { onOpenHistory?() }
    @objc private func openSettings() { onOpenSettings?() }
    @objc private func copyLast() { onCopyLastTranscript?() }
}
