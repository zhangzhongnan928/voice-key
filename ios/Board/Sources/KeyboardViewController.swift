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
    /// Tries every known opener; modern iOS quietly killed the old
    /// responder-chain `openURL:` (the perform "succeeds", nothing opens).
    /// The status label tags the path taken so on-device runs tell us
    /// which one actually works.
    @objc private func micTapped() {
        guard let url = URL(string: "voicekey://record") else { return }

        if let app = applicationOnResponderChain(), openViaApplication(app, url: url) {
            statusLabel.text = "Recording in VoiceKey — swipe back when done. (A)"
            return
        }

        guard let extensionContext else {
            statusLabel.text = "Could not open VoiceKey. Open it manually to dictate."
            return
        }
        extensionContext.open(url) { [weak self] success in
            DispatchQueue.main.async {
                self?.statusLabel.text = success
                    ? "Recording in VoiceKey — swipe back when done. (B)"
                    : "Could not open VoiceKey. Open it manually to dictate."
            }
        }
    }

    /// Walks the responder chain for the hosting UIApplication instance —
    /// extensions can't reference UIApplication.shared at compile time, but
    /// the instance is reachable at runtime.
    private func applicationOnResponderChain() -> UIApplication? {
        var responder: UIResponder? = self
        while let current = responder {
            if let app = current as? UIApplication { return app }
            responder = current.next
        }
        return nil
    }

    /// Calls open(_:options:completionHandler:) (falling back to the legacy
    /// openURL:) through the ObjC runtime, since both are marked unavailable
    /// in extensions at compile time.
    private func openViaApplication(_ app: UIApplication, url: URL) -> Bool {
        let modern = NSSelectorFromString("openURL:options:completionHandler:")
        if app.responds(to: modern) {
            typealias OpenFn = @convention(c) (UIApplication, Selector, NSURL, NSDictionary, Any?) -> Void
            let fn = unsafeBitCast(app.method(for: modern), to: OpenFn.self)
            fn(app, modern, url as NSURL, [:], nil)
            return true
        }
        let legacy = NSSelectorFromString("openURL:")
        if app.responds(to: legacy) {
            app.perform(legacy, with: url)
            return true
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
