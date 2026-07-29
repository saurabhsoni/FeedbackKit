import Foundation
import Security

/// Who sent a report.
///
/// Two pieces: a display name the person types once, and a random install ID
/// used only to group one person's reports together over time.
///
/// The install ID is **not** `identifierForVendor`. IDFV resets to a new value
/// once every app from the same vendor is deleted from the device, which would
/// silently split one person's history in two. A UUID we generate and keep in
/// the keychain survives delete-and-reinstall, so "the same three people keep
/// reporting things" stays true across the 7-day rebuild cycle a free Apple
/// team forces.
///
/// It identifies an *install*, not a person: it is random, is never joined
/// against anything, and is not derived from any hardware identifier.
struct FeedbackIdentity: Sendable {
    let installID: String
    var reporterName: String?

    private static let service = "in.saurabhsoni.feedbackkit"
    private static let installAccount = "installID.v1"
    private static let nameAccount = "reporterName.v1"

    static func load() -> FeedbackIdentity {
        FeedbackIdentity(
            installID: loadOrCreateInstallID(),
            reporterName: string(for: nameAccount)
        )
    }

    static func saveReporterName(_ name: String?) {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmed, !trimmed.isEmpty else {
            delete(account: nameAccount)
            return
        }
        set(Data(trimmed.utf8), account: nameAccount)
    }

    private static func loadOrCreateInstallID() -> String {
        if let existing = string(for: installAccount), !existing.isEmpty {
            return existing
        }
        let fresh = UUID().uuidString.lowercased()
        set(Data(fresh.utf8), account: installAccount)
        return fresh
    }

    // MARK: - Keychain

    /// No access group: unlike the app↔widget sharing elsewhere in these
    /// projects, nothing outside the app needs to read this, and staying out of
    /// a shared group keeps the item working regardless of team prefix.
    private static func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private static func string(for account: String) -> String? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data
        else { return nil }

        return String(data: data, encoding: .utf8)
    }

    private static func set(_ data: Data, account: String) {
        let query = baseQuery(account: account)
        let status = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        guard status == errSecItemNotFound else { return }

        var insert = query
        insert[kSecValueData as String] = data
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(insert as CFDictionary, nil)
    }

    private static func delete(account: String) {
        SecItemDelete(baseQuery(account: account) as CFDictionary)
    }
}
