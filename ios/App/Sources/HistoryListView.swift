import SwiftUI

struct HistoryListView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        NavigationStack {
            List {
                if model.historyItems.isEmpty {
                    Text("No transcripts yet.")
                        .foregroundStyle(.secondary)
                }
                ForEach(model.historyItems) { item in
                    HistoryRow(item: item)
                }
            }
            .navigationTitle("History")
            .refreshable { model.reloadHistory() }
            .onAppear { model.reloadHistory() }
        }
    }
}

private struct HistoryRow: View {
    @EnvironmentObject var model: AppModel
    let item: TranscriptItem

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
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: stateSymbol.name)
                    .foregroundStyle(stateSymbol.color)
                Text(item.createdAt, format: .dateTime.month().day().hour().minute())
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(durationText)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Text(item.state == .failed ? (item.error ?? "Failed") : item.firstLine)
                .lineLimit(2)
                .foregroundStyle(item.state == .failed ? .red : .primary)
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                model.delete(item: item)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .swipeActions(edge: .leading) {
            if let text = item.text {
                Button {
                    UIPasteboard.general.string = text
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
            }
            if item.state == .failed {
                Button {
                    model.retry(item: item)
                } label: {
                    Label("Retry", systemImage: "arrow.clockwise")
                }
            }
        }
    }
}
