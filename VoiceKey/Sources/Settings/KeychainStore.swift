import Foundation
import os
import Security

/// Stores the OpenAI API key in the login keychain. The key never touches
/// files, UserDefaults, or logs. Failures log and return the OSStatus (never
/// key material) — a silent `nil`/`false` here once cost a morning of
/// debugging when a broken app signature made the keychain deny access.
struct KeychainStore {
    private static let log = Logger(subsystem: "com.victor.voicekey", category: "keychain")

    private let service = "com.victor.voicekey"
    private let account = "openai_api_key"

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    func apiKey() -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            if status != errSecItemNotFound {
                // errSecAuthFailed (-25293) with an existing item usually means
                // the ACL rejected this app — e.g. the bundle signature broke.
                Self.log.error("read failed: \(Self.describe(status), privacy: .public)")
            }
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    /// Returns `errSecSuccess` on success; any other status is the failing
    /// Security-framework call's result, for display to the user.
    @discardableResult
    func setAPIKey(_ key: String) -> OSStatus {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return deleteAPIKey() }
        let data = Data(trimmed.utf8)

        let updateStatus = SecItemUpdate(
            baseQuery as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updateStatus == errSecSuccess { return errSecSuccess }
        guard updateStatus == errSecItemNotFound else {
            Self.log.error("update failed: \(Self.describe(updateStatus), privacy: .public)")
            return updateStatus
        }

        var addStatus = add(data)
        if addStatus == errSecDuplicateItem {
            // An item exists that the update above could not see (stale
            // accessibility or access group). Replace it outright.
            SecItemDelete(baseQuery as CFDictionary)
            addStatus = add(data)
        }
        if addStatus != errSecSuccess {
            Self.log.error("add failed: \(Self.describe(addStatus), privacy: .public)")
        }
        return addStatus
    }

    /// Returns `errSecSuccess` when the key is gone (including "was never
    /// there"); any other status is the failure to show the user.
    @discardableResult
    func deleteAPIKey() -> OSStatus {
        let status = SecItemDelete(baseQuery as CFDictionary)
        if status == errSecSuccess || status == errSecItemNotFound { return errSecSuccess }
        Self.log.error("delete failed: \(Self.describe(status), privacy: .public)")
        return status
    }

    /// Human-readable form of an OSStatus, e.g. "-25293: The user name or
    /// passphrase you entered is not correct."
    static func describe(_ status: OSStatus) -> String {
        let message = SecCopyErrorMessageString(status, nil) as String? ?? "unknown Security error"
        return "\(status): \(message)"
    }

    private func add(_ data: Data) -> OSStatus {
        var addQuery = baseQuery
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        return SecItemAdd(addQuery as CFDictionary, nil)
    }
}
