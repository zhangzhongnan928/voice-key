import SwiftUI

/// Main screen: one large record button (Prompt 2 spec).
struct RecordView: View {
    @EnvironmentObject var model: AppModel

    private var timeText: String {
        let total = Int(model.elapsed)
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    var body: some View {
        VStack(spacing: 24) {
            if let warning = model.setupWarning {
                Text(warning)
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }

            if model.showReturnBanner {
                returnBanner
            }

            Spacer()

            Button {
                model.toggleRecording()
            } label: {
                ZStack {
                    Circle()
                        .fill(model.isRecording ? Color.red : Color.accentColor)
                        .frame(width: 160, height: 160)
                    Image(systemName: model.isRecording ? "stop.fill" : "mic.fill")
                        .font(.system(size: 56))
                        .foregroundStyle(.white)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(model.isRecording ? "Stop recording" : "Start recording")

            if model.isRecording {
                VStack(spacing: 8) {
                    Text(timeText)
                        .font(.title2.monospacedDigit())
                    ProgressView(value: Double(model.level))
                        .frame(width: 160)
                    Button("Cancel", role: .destructive) {
                        model.cancelRecording()
                    }
                }
            } else if !model.statusText.isEmpty {
                Text(model.statusText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }

            if let last = model.lastTranscript, !model.isRecording {
                VStack(spacing: 6) {
                    Text(last)
                        .lineLimit(4)
                        .padding()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
                    Button("Copy") {
                        UIPasteboard.general.string = last
                    }
                    .font(.callout)
                }
                .padding(.horizontal)
            }

            Spacer()

            Text(String(format: "This month: $%.2f — this device only (estimate). Authoritative usage: OpenAI dashboard.", model.monthlyCost))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
        .padding(.vertical)
    }

    /// iOS offers no API to identify or switch to the previous app, so the
    /// banner instructs the user to swipe back (Prompt 2 patch).
    private var returnBanner: some View {
        VStack(spacing: 4) {
            Text("Transcript ready")
                .font(.headline)
            Text("Swipe back to the app you were typing in — the keyboard will insert it automatically.")
                .font(.subheadline)
                .multilineTextAlignment(.center)
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(Color.green.opacity(0.2), in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal)
    }
}
