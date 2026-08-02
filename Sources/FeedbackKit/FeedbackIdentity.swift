import Foundation
import Security

/// Who the host app says is using it.
///
/// The point of this type is to delete a question. Asking someone to type their
/// name into a feedback form is asking them for something the app already knows,
/// and the answer is worse than the one it has — people type "me", or nothing.
/// An app with accounts passes this in and the name field disappears.
///
/// Both halves are optional and mean different things. `id` is a stable account
/// identifier (Apple's `userID` for a Sign in with Apple app) and is what makes
/// history follow someone onto a second device; `displayName` is only ever shown
/// back to them and written to `reporter`. Sign in with Apple hands over a name
/// exactly once and only if the user allows it, so an app can perfectly well
/// have an `id` and no name — in which case the typed field comes back.
public struct FeedbackUser: Sendable, Equatable {
    public let id: String?
    public let displayName: String?

    public init(id: String?, displayName: String?) {
        self.id = id
        self.displayName = displayName
    }

    /// The name with the empty cases folded into `nil`, since " " and "" both
    /// mean "no name" and only one of them is easy to test for.
    var resolvedName: String? {
        guard let trimmed = displayName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty
        else { return nil }
        return trimmed
    }

    /// The same folding for the id. An empty string could never match anything
    /// — `feedback_for_install` guards on `char_length(p_user_id) >= 16` — but
    /// it would still be written into `user_id`, leaving a column full of `""`
    /// that looks like data and isn't.
    var resolvedID: String? {
        guard let id, !id.isEmpty else { return nil }
        return id
    }
}

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

    /// Adopts the name the host app supplies, overwriting anything typed here
    /// before.
    ///
    /// Deliberately destructive. Once an app knows who someone is, the name it
    /// knows is the right one, and leaving a stale hand-typed "s" in the
    /// keychain would mean reports going out under a name the person has no
    /// memory of choosing and no way to edit — the field that used to edit it
    /// is gone. Idempotent, so running it on every launch is fine.
    static func adoptHostName(_ name: String) {
        saveReporterName(name)
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
            kSecAttrAccount as String: account
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
