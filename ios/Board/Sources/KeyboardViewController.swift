import GRDB
import UIKit

/// "VoiceKey Board" — minimal keyboard (Prompt 2):
/// - mic button: opens the container app via the responder-chain openURL
///   workaround (keyboards cannot record; there is no workaround for that)
/// - "Insert latest": inserts the newest done transcript from the shared store
/// - one-line status label
/// - globe key (needsInputModeSwitchKey)
///
/// The keyboard READS the App Group SQLite only (WAL; the container app is
/// the writer). It never holds the API key and never makes network calls.
final class KeyboardViewController: UIInputViewController {
    private let statusLabel = UILabel()
    private let micButton = UIButton(type: .system)
    private let insertButton = UIButton(type: .system)
    private let globeButton = UIButton(type: .system)

    private var store: TranscriptStore?

    override func viewDidLoad() {
        super.viewDidLoad()
        buildLayout()
        openStoreIfPossible()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        refreshStatus()
        autoInsertPendingIfAny()
    }

    // MARK: Store

    private func openStoreIfPossible() {
        guard hasFullAccess else { return }
        guard store == nil else { return }
        guard let dbURL = AppGroup.databaseURL,
              FileManager.default.fileExists(atPath: dbURL.path) else { return }
        store = try? TranscriptStore(path: dbURL.path)
    }

    // MARK: Flow

    /// M3: consume-once auto-insert. Expired or consumed entries are never
    /// auto-inserted (10 min TTL enforced by the store).
    private func autoInsertPendingIfAny() {
        openStoreIfPossible()
        guard let store, let text = try? store.consumePendingInsert() else { return }
        textDocumentProxy.insertText(text)
        statusLabel.text = "Inserted."
    }

    @objc private func insertLatestTapped() {
        openStoreIfPossible()
        guard hasFullAccess else {
            statusLabel.text = "Enable Full Access in Settings to use VoiceKey."
            return
        }
        guard let store, let item = try? store.lastDone(), let text = item.text else {
            statusLabel.text = "No transcript yet — tap the mic to dictate."
            return
        }
        textDocumentProxy.insertText(text)
        statusLabel.text = "Inserted."
    }

    /// Opens the container app to record (keyboards cannot use the mic).
    @objc private func micTapped() {
        guard let url = URL(string: "voicekey://record") else { return }
        if openViaResponderChain(url) {
            statusLabel.text = "Recording in VoiceKey — swipe back when done."
        } else {
            statusLabel.text = "Could not open VoiceKey. Open it manually to dictate."
        }
    }

    /// Responder-chain openURL workaround: extensions have no UIApplication,
    /// but a host responder up the chain implements openURL:. Fine for
    /// TestFlight internal / Ad Hoc distribution.
    @discardableResult
    private func openViaResponderChain(_ url: URL) -> Bool {
        let selector = sel_registerName("openURL:")
        var responder: UIResponder? = self
        while let current = responder {
            if current.responds(to: selector) {
                current.perform(selector, with: url)
                return true
            }
            responder = current.next
        }
        return false
    }

    private func refreshStatus() {
        guard hasFullAccess else {
            statusLabel.text = "Enable Full Access in Settings to use VoiceKey."
            return
        }
        openStoreIfPossible()
        statusLabel.text = "Tap the mic to dictate in VoiceKey."
    }

    // MARK: Layout

    private func buildLayout() {
        view.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.font = .preferredFont(forTextStyle: .footnote)
        statusLabel.textColor = .secondaryLabel
        statusLabel.textAlignment = .center
        statusLabel.adjustsFontSizeToFitWidth = true
        statusLabel.numberOfLines = 1

        var micConfig = UIButton.Configuration.filled()
        micConfig.image = UIImage(systemName: "mic.fill")
        micConfig.title = "Dictate"
        micConfig.imagePadding = 8
        micConfig.cornerStyle = .large
        micButton.configuration = micConfig
        micButton.addTarget(self, action: #selector(micTapped), for: .touchUpInside)

        var insertConfig = UIButton.Configuration.gray()
        insertConfig.image = UIImage(systemName: "text.insert")
        insertConfig.title = "Insert latest"
        insertConfig.imagePadding = 8
        insertConfig.cornerStyle = .large
        insertButton.configuration = insertConfig
        insertButton.addTarget(self, action: #selector(insertLatestTapped), for: .touchUpInside)

        globeButton.setImage(UIImage(systemName: "globe"), for: .normal)
        globeButton.addTarget(self, action: #selector(handleInputModeList(from:with:)), for: .allTouchEvents)

        let buttonRow = UIStackView(arrangedSubviews: [globeButton, micButton, insertButton])
        buttonRow.axis = .horizontal
        buttonRow.spacing = 12
        buttonRow.alignment = .fill
        buttonRow.distribution = .fill

        let column = UIStackView(arrangedSubviews: [statusLabel, buttonRow])
        column.axis = .vertical
        column.spacing = 10
        column.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(column)

        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            column.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            column.topAnchor.constraint(equalTo: view.topAnchor, constant: 10),
            column.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -10),
            view.heightAnchor.constraint(greaterThanOrEqualToConstant: 120),
            globeButton.widthAnchor.constraint(equalToConstant: 44),
            micButton.widthAnchor.constraint(equalTo: insertButton.widthAnchor),
        ])

        globeButton.isHidden = !needsInputModeSwitchKey
    }
}
