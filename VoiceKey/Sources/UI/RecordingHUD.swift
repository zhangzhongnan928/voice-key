import AppKit
import SwiftUI

/// State shared with the HUD view.
final class HUDModel: ObservableObject {
    @Published var level: Float = 0
    @Published var elapsed: TimeInterval = 0
    @Published var warning = false
}

struct HUDView: View {
    @ObservedObject var model: HUDModel

    private var timeText: String {
        let total = Int(model.elapsed)
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "mic.fill")
                .foregroundStyle(.red)
            LevelMeter(level: model.level)
                .frame(width: 90, height: 14)
            Text(timeText)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(model.warning ? .orange : .primary)
            Text("Esc to cancel")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}

struct LevelMeter: View {
    var level: Float
    private let barCount = 12

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<barCount, id: \.self) { index in
                RoundedRectangle(cornerRadius: 1)
                    .fill(Float(index) / Float(barCount) < level ? Color.green : Color.gray.opacity(0.3))
            }
        }
    }
}

/// Small floating non-activating panel near the top of the screen (F2).
/// Never steals focus from the app being dictated into.
final class RecordingHUDController {
    let model = HUDModel()
    private var panel: NSPanel?

    func show() {
        model.level = 0
        model.elapsed = 0
        model.warning = false

        let hosting = NSHostingView(rootView: HUDView(model: model))
        hosting.frame = NSRect(x: 0, y: 0, width: 280, height: 36)

        let panel = NSPanel(
            contentRect: hosting.frame,
            styleMask: [.nonactivatingPanel, .borderless, .hudWindow],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = hosting

        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(
                x: frame.midX - hosting.frame.width / 2,
                y: frame.maxY - hosting.frame.height - 8
            ))
        }
        panel.orderFrontRegardless()
        self.panel = panel
    }

    func hide() {
        panel?.orderOut(nil)
        panel = nil
    }
}
