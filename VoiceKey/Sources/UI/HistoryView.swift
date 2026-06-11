import AppKit
import SwiftUI

/// Actions a history row can trigger; implemented by AppController.
@MainActor
protocol HistoryActions: AnyObject {
    func historyCopy(item: TranscriptItem)
    func historyReinsert(item: TranscriptItem)
    func historyRetry(item: TranscriptItem)
    func historyDelete(item: TranscriptItem)
}

@MainActor
final class HistoryViewModel: ObservableObject {
    @Published var items: [TranscriptItem] = []
    @Published var search = "" {
        didSet { reload() }
    }

    private let store: TranscriptStore
    private let limit: () -> Int
    weak var actions: HistoryActions?

    init(store: TranscriptStore, limit: @escaping () -> Int) {
        self.store = store
        self.limit = limit
    }

    func reload() {
        let fetchLimit = max(limit(), 1)
        items = (try? store.recent(limit: fetchLimit, search: search.isEmpty ? nil : search)) ?? []
    }

    func appName(for item: TranscriptItem) -> String {
        if let name = item.appName, !name.isEmpty { return name }
        guard let bundleId = item.appBundleId else { return "—" }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else {
            return bundleId
        }
        return FileManager.default.displayName(atPath: url.path)
            .replacingOccurrences(of: ".app", with: "")
    }
}

struct HistoryView: View {
    @ObservedObject var model: HistoryViewModel

    var body: some View {
        VStack(spacing: 0) {
            TextField("Search transcripts", text: $model.search)
                .textFieldStyle(.roundedBorder)
                .padding(8)

            if model.items.isEmpty {
                Text(model.search.isEmpty ? "No transcripts yet." : "No matches.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(model.items) { item in
                    HistoryRow(item: item, model: model)
                }
                .listStyle(.plain)
            }
        }
        .frame(width: 380, height: 420)
        .onAppear { model.reload() }
    }
}

private struct HistoryRow: View {
    let item: TranscriptItem
    @ObservedObject var model: HistoryViewModel

    private var stateSymbol: (name: String, color: Color) {
        switch item.state {
        case .recording: return ("record.circle", .red)
        case .queued: return ("clock", .orange)
        case .uploading: return ("arrow.up.circle", .blue)
        case .done: return ("checkmark.circle", .green)
        case .failed: return ("exclamationmark.triangle", .red)
        }
    }

    private var durationText: String {
        let seconds = Int(item.durationS.rounded())
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: stateSymbol.name)
                    .foregroundStyle(stateSymbol.color)
                Text(item.createdAt, format: .dateTime.month().day().hour().minute())
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(durationText)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Text(model.appName(for: item))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
            }

            Text(item.state == .failed ? (item.error ?? "Failed") : item.firstLine)
                .lineLimit(1)
                .foregroundStyle(item.state == .failed ? .red : .primary)

            HStack(spacing: 12) {
                if item.text != nil {
                    Button("Copy") { model.actions?.historyCopy(item: item) }
                    Button("Insert") { model.actions?.historyReinsert(item: item) }
                }
                if item.state == .failed {
                    Button("Retry") { model.actions?.historyRetry(item: item); model.reload() }
                }
                Button(role: .destructive) {
                    model.actions?.historyDelete(item: item)
                    model.reload()
                } label: {
                    Text("Delete")
                }
            }
            .buttonStyle(.link)
            .font(.caption)
        }
        .padding(.vertical, 3)
    }
}

/// NSPopover wrapper anchored to the status item.
@MainActor
final class HistoryPopoverController {
    private let popover = NSPopover()
    let model: HistoryViewModel

    init(store: TranscriptStore, limit: @escaping () -> Int) {
        model = HistoryViewModel(store: store, limit: limit)
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: HistoryView(model: model))
    }

    func toggle(relativeTo button: NSStatusBarButton?) {
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        guard let button else { return }
        model.reload()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }
}
