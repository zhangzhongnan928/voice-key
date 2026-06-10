import os

/// Central loggers. Privacy rule: transcript text must never be logged at
/// info level or below — use `.debug` with `.private` redaction if needed.
enum Log {
    static let app = Logger(subsystem: "com.victor.voicekey", category: "app")
    static let audio = Logger(subsystem: "com.victor.voicekey", category: "audio")
    static let store = Logger(subsystem: "com.victor.voicekey", category: "store")
    static let net = Logger(subsystem: "com.victor.voicekey", category: "net")
    static let insert = Logger(subsystem: "com.victor.voicekey", category: "insert")
}
