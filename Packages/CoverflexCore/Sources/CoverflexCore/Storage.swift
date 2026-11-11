import Foundation
import Security

/// App Group shared by the app and the widget extension. Holds the snapshot and is the Keychain access group.
public enum AppGroup {
    /// App Group in `project.yml` and the `.entitlements` files.
    public static let declaredIdentifier = "group.com.gmcabrita.CoverflexBudget"

    /// App Group in the signed app.
    public static let identifier = resolve(altStoreAppGroups: Bundle.main.object(forInfoDictionaryKey: "ALTAppGroups") as? [String])

    /// AltStore and SideStore re-sign the app with a free developer account and rename each App Group
    /// to `<declared>.<TEAMID>`. They list the new names under `ALTAppGroups` in the `Info.plist`
    /// of the app and of each extension. Without that key, the app runs with the declared App Group.
    static func resolve(altStoreAppGroups: [String]?) -> String {
        let renamed = (altStoreAppGroups ?? []).filter { $0.hasPrefix(declaredIdentifier + ".") }
        return renamed.min(by: { $0.count < $1.count }) ?? declaredIdentifier
    }
}

/// Stores one secret value, such as the tokens or the credentials.
public protocol SecureStore<Value>: Sendable {
    associatedtype Value
    func load() -> Value?
    func save(_ value: Value) throws
    func clear()
}

/// Stores the last known budget for the widget.
public protocol SnapshotStore: Sendable {
    func load() -> BudgetSnapshot
    func save(_ snapshot: BudgetSnapshot)
}

/// Keeps one value as JSON in the Keychain. The App Group identifier is the access group,
/// so the app and the widget extension read the same item.
public struct KeychainStore<Value: Codable & Sendable>: SecureStore {
    private let service = "com.gmcabrita.CoverflexBudget"
    private let account: String
    private let accessGroup: String?

    public init(account: String, accessGroup: String? = AppGroup.identifier) {
        self.account = account
        self.accessGroup = accessGroup
    }

    public func load() -> Value? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data
        else { return nil }
        return try? JSONDecoder().decode(Value.self, from: data)
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
