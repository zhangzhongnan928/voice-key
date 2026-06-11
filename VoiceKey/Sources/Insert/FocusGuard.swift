import Foundation

/// CR-2: auto-insert only when focus is still where dictation happened.
/// Pure decision logic; injected state makes it unit-testable.
enum FocusGuard {
    static let defaultWindowSeconds: TimeInterval = 120

    /// Allow synthetic paste only if the frontmost app is unchanged since
    /// recording stopped AND the transcript arrived within the guard window.
    /// With the guard disabled, insertion is always allowed. Unknown app
    /// identity or stop time fails safe (clipboard only).
    static func shouldAutoInsert(
        enabled: Bool,
        storedBundleId: String?,
        currentBundleId: String?,
        stoppedAt: Date?,
        now: Date,
        windowSeconds: TimeInterval
    ) -> Bool {
        guard enabled else { return true }
        guard let storedBundleId, let currentBundleId, storedBundleId == currentBundleId else {
            return false
        }
        guard let stoppedAt, now.timeIntervalSince(stoppedAt) <= windowSeconds else {
            return false
        }
        return true
    }
}

/// CR-3: restore the pre-dictation clipboard only if nobody wrote to the
/// pasteboard after us — i.e. the changeCount still matches the value we
/// observed right after writing the transcript.
enum ClipboardRestorePolicy {
    static func shouldRestore(changeCountAtWrite: Int, currentChangeCount: Int) -> Bool {
        currentChangeCount == changeCountAtWrite
    }
}
