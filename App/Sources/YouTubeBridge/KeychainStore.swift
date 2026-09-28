import Foundation
import Security

/// Stores the YouTube cookie header in the Keychain (no access group, so it follows whatever
/// bundle id / team the sideloading tool signs the app with). Failures are logged: a sign-in
/// that can't be saved or read is otherwise just gone after the next launch.
final class KeychainStore: @unchecked Sendable {
    private let service = "tube.youtube.session"
    private let account = "cookies"
    private let logs: LogBuffer

    init(logs: LogBuffer) {
        self.logs = logs
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    func loadCookie() -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            logs.append(.error, "Couldn't read the sign-in from the Keychain: \(Self.describe(status))")
            return nil
        }
        guard let data = item as? Data, let text = String(data: data, encoding: .utf8),
              !text.isEmpty else { return nil }
        return text
    }

    /// Returns false (and logs why) when the Keychain didn't store it.
    @discardableResult
    func saveCookie(_ cookie: String) -> Bool {
        let data = Data(cookie.utf8)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        var status = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var add = baseQuery
            add.merge(attributes) { $1 }
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            logs.append(.error, "Couldn't save the sign-in to the Keychain: \(Self.describe(status))")
            return false
        }
        return true
    }

    func deleteCookie() {
        let status = SecItemDelete(baseQuery as CFDictionary)
        if status != errSecSuccess, status != errSecItemNotFound {
            logs.append(.error, "Couldn't delete the sign-in from the Keychain: \(Self.describe(status))")
        }
    }

    private static func describe(_ status: OSStatus) -> String {
        let text = SecCopyErrorMessageString(status, nil) as String? ?? "unknown error"
        return "\(text) (OSStatus \(status))"
    }
}
