import Foundation
import LocalAuthentication
import Security

enum KeychainAccount: String {
    case vpnUsername = "vpn-username"
    case vpnPassword = "vpn-password"
    case vpnCredentials = "vpn-credentials"
}

private struct StoredCredentialsPayload: Codable {
    let username: String
    let password: String
}

enum KeychainService {
    private static let service = "com.3tty0n.vpn-auto-connect"
    private static let cacheLock = NSLock()
    private static var cachedCredentials: Credentials?
    private static var sharedAuthContext: LAContext?

    static func saveVPNCredentials(username: String, password: String) throws {
        let payload = StoredCredentialsPayload(username: username, password: password)
        let data = try JSONEncoder().encode(payload)

        setCached(Credentials(username: username, password: password))

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: KeychainAccount.vpnCredentials.rawValue,
        ]

        SecItemDelete(query as CFDictionary)

        var addQuery = query
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let status = SecItemAdd(addQuery as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.saveFailed(status)
        }

        deleteLegacySplitItems()
    }

    static func loadVPNCredentials() -> Credentials? {
        if let cached = cachedValue() {
            return cached
        }

        if let combined = loadCombinedCredentials() {
            setCached(combined)
            return combined
        }

        if let legacy = loadLegacySplitCredentials() {
            setCached(legacy)
            try? saveVPNCredentials(username: legacy.username, password: legacy.password)
            return legacy
        }

        return nil
    }

    static func hasStoredCredentials() -> Bool {
        if cachedValue() != nil {
            return true
        }

        if itemExists(account: KeychainAccount.vpnCredentials.rawValue) {
            return true
        }

        return itemExists(account: KeychainAccount.vpnUsername.rawValue)
            && itemExists(account: KeychainAccount.vpnPassword.rawValue)
    }

    static func deleteVPNCredentials() {
        cacheLock.lock()
        cachedCredentials = nil
        sharedAuthContext = nil
        cacheLock.unlock()

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        SecItemDelete(query as CFDictionary)
    }

    static func migrateLegacyPasswordIfNeeded(fallbackUsername: String) {
        guard !hasStoredCredentials() else { return }

        let legacyQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: KeychainAccount.vpnPassword.rawValue,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        guard
            SecItemCopyMatching(legacyQuery as CFDictionary, &result) == errSecSuccess,
            let data = result as? Data,
            let password = String(data: data, encoding: .utf8),
            !password.isEmpty
        else {
            return
        }

        let username = fallbackUsername.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !username.isEmpty else { return }

        try? saveVPNCredentials(username: username, password: password)
    }

    private static func loadCombinedCredentials() -> Credentials? {
        guard
            let data = loadData(account: KeychainAccount.vpnCredentials.rawValue),
            let payload = try? JSONDecoder().decode(StoredCredentialsPayload.self, from: data),
            !payload.username.isEmpty,
            !payload.password.isEmpty
        else {
            return nil
        }

        return Credentials(username: payload.username, password: payload.password)
    }

    private static func loadLegacySplitCredentials() -> Credentials? {
        let context = authenticationContext()
        guard
            let username = loadString(account: KeychainAccount.vpnUsername.rawValue, context: context),
            let password = loadString(account: KeychainAccount.vpnPassword.rawValue, context: context),
            !username.isEmpty,
            !password.isEmpty
        else {
            return nil
        }

        return Credentials(username: username, password: password)
    }

    private static func authenticationContext() -> LAContext {
        cacheLock.lock()
        defer { cacheLock.unlock() }

        if let sharedAuthContext {
            return sharedAuthContext
        }

        let context = LAContext()
        context.localizedReason = "Access VPN credentials stored in Keychain"
        sharedAuthContext = context
        return context
    }

    private static func loadData(account: String, context: LAContext? = nil) -> Data? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        let authContext = context ?? authenticationContext()
        query[kSecUseAuthenticationContext as String] = authContext

        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data
        else {
            return nil
        }

        return data
    }

    private static func loadString(account: String, context: LAContext) -> String? {
        guard let data = loadData(account: account, context: context) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func itemExists(account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: false,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    private static func deleteLegacySplitItems() {
        for account in [KeychainAccount.vpnUsername.rawValue, KeychainAccount.vpnPassword.rawValue] {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
            ]
            SecItemDelete(query as CFDictionary)
        }
    }

    private static func cachedValue() -> Credentials? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return cachedCredentials
    }

    private static func setCached(_ credentials: Credentials) {
        cacheLock.lock()
        cachedCredentials = credentials
        cacheLock.unlock()
    }
}

enum KeychainError: LocalizedError {
    case saveFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .saveFailed(let status):
            return "Keychain save failed (status: \(status))"
        }
    }
}
