import Foundation

/// Lifecycle of a recording. Terminal states are `done` and `failed`.
///
///     recording -> queued -> uploading -> done
///         |           ^          |
///         v           |          v
///       failed        +-------- queued (retry)   uploading -> failed
///                                                failed -> queued (manual retry)
enum ItemState: String, Codable, CaseIterable {
    case recording
    case queued
    case uploading
    case done
    case failed

    var isTerminal: Bool { self == .done || self == .failed }

    func canTransition(to next: ItemState) -> Bool {
        switch (self, next) {
        case (.recording, .queued),
             (.recording, .failed),
             (.queued, .uploading),
             (.queued, .failed),
             (.uploading, .done),
             (.uploading, .queued),
             (.uploading, .failed),
             (.failed, .queued):
            return true
        default:
            return false
        }
    }
}
