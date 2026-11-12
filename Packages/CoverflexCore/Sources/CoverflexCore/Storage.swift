import Foundation
import Security

/// App Group shared by the app and the widget extension. Holds the snapshot and is the Keychain access group.
public enum AppGroup {
    /// App Group in the signed app.
    public static let identifier = resolve(
        declared: declaredIdentifier,
        altStoreAppGroups: Bundle.main.object(forInfoDictionaryKey: "ALTAppGroups") as? [String]
    )

    /// App Group in the `.entitlements` files. `project.yml` builds it from `IOS_BUNDLE_ID_PREFIX`
    /// and writes it to `CoverflexAppGroup` in the `Info.plist` of the app and of the widget.
    private static var declaredIdentifier: String {
        guard let declared = Bundle.main.object(forInfoDictionaryKey: "CoverflexAppGroup") as? String else {
            fatalError("CoverflexAppGroup is missing from Info.plist. Run xcodegen generate.")
        }
        return declared
    }

    /// AltStore and SideStore re-sign the app with a free developer account and rename each App Group
    /// to `<declared>.<TEAMID>`. They list the new names under `ALTAppGroups` in the `Info.plist`
    /// of the app and of each extension. Without that key, the app runs with the declared App Group.
    static func resolve(declared: String, altStoreAppGroups: [String]?) -> String {
        let renamed = (altStoreAppGroups ?? []).filter { $0.hasPrefix(declared + ".") }
        return renamed.min(by: { $0.count < $1.count }) ?? declared
    }
}

/// Stores one secret value, such as the tokens or the credentials.
public protocol SecureStore<Value>: Sendable {
    associatedtype Value
    /// Nil when no value is stored. Throws when the store cannot read the value or the value
    /// no longer decodes, so callers can tell "no value" from "value unreadable now".
    func load() throws -> Value?
    func save(_ value: Value) throws
    func clear()
}

/// Stores the last known budget for the widget.
public protocol SnapshotStore: Sendable {
    func load() -> BudgetSnapshot
    func save(_ snapshot: BudgetSnapshot)
}

/// Stores the last renew issue for the app's diagnostics.
public protocol RenewIssueStore: Sendable {
    func load() -> RenewIssue?
    func save(_ issue: RenewIssue)
}

/// Keeps one value as JSON in the Keychain. The App Group identifier is the access group,
/// so the app and the widget extension read the same item.
public struct KeychainStore<Value: Codable & Sendable>: SecureStore {
    // Only a label inside this app's access group, so it does not depend on BUNDLE_ID_PREFIX.
    // Changing it would hide the sessions that are already saved.
    private let service = "com.gmcabrita.CoverflexBudget"
    private let account: String
    private let accessGroup: String?

    public init(account: String, accessGroup: String? = AppGroup.identifier) {
        self.account = account
        self.accessGroup = accessGroup
    }

    public func load() throws -> Value? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        // For example errSecInteractionNotAllowed: the widget refreshes before the first unlock after a restart.
        guard status == errSecSuccess, let data = result as? Data else { throw KeychainError(status: status) }
        return try JSONDecoder().decode(Value.self, from: data)
    }

    public func save(_ value: Value) throws {
        let data = try JSONEncoder().encode(value)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            // The widget refreshes in the background, also while the device is locked.
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        var status = SecItemUpdate(baseQuery() as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            let query = baseQuery().merging(attributes) { _, new in new }
            status = SecItemAdd(query as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    public func clear() {
        SecItemDelete(baseQuery() as CFDictionary)
    }

    private func baseQuery() -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        return query
    }
}

extension KeychainStore where Value == StoredSession {
    public static var session: Self { Self(account: "session") }
}

public struct KeychainError: Error, LocalizedError {
    public let status: OSStatus

    public var errorDescription: String? {
        let message = SecCopyErrorMessageString(status, nil) as String? ?? "Unknown error"
        return "Keychain error \(status): \(message)"
    }
}

/// Keeps the snapshot as JSON in the App Group `UserDefaults`.
public struct AppGroupSnapshotStore: SnapshotStore {
    private static let key = "budgetSnapshot"
    private let suiteName: String

    public init(suiteName: String = AppGroup.identifier) {
        self.suiteName = suiteName
    }

    // `UserDefaults` is thread safe but not `Sendable`, so each call opens the suite.
    private var defaults: UserDefaults { UserDefaults(suiteName: suiteName) ?? .standard }

    public func load() -> BudgetSnapshot {
        guard let data = defaults.data(forKey: Self.key),
              let snapshot = try? JSONDecoder().decode(BudgetSnapshot.self, from: data)
        else { return BudgetSnapshot() }
        return snapshot
    }

    public func save(_ snapshot: BudgetSnapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: Self.key)
    }
}

/// Keeps the last renew issue as JSON in the App Group `UserDefaults`, apart from the snapshot,
/// so a snapshot save in another process cannot erase it.
public struct AppGroupRenewIssueStore: RenewIssueStore {
    private static let key = "lastRenewIssue"
    private let suiteName: String

    public init(suiteName: String = AppGroup.identifier) {
        self.suiteName = suiteName
    }

    private var defaults: UserDefaults { UserDefaults(suiteName: suiteName) ?? .standard }

    public func load() -> RenewIssue? {
        guard let data = defaults.data(forKey: Self.key) else { return nil }
        return try? JSONDecoder().decode(RenewIssue.self, from: data)
    }

    public func save(_ issue: RenewIssue) {
        guard let data = try? JSONEncoder().encode(issue) else { return }
        defaults.set(data, forKey: Self.key)
    }
}
