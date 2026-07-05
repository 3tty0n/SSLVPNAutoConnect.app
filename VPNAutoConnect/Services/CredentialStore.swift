import Foundation

enum CredentialStore {
    static func resolve() throws -> Credentials {
        guard let credentials = KeychainService.loadVPNCredentials() else {
            throw CredentialError.keychainCredentialsMissing
        }
        return credentials
    }

    static func resolveOptional() -> Credentials? {
        KeychainService.loadVPNCredentials()
    }

    static func save(username: String, password: String) throws {
        try KeychainService.saveVPNCredentials(username: username, password: password)
    }

    static func hasKeychainCredentials() -> Bool {
        KeychainService.hasStoredCredentials()
    }
}

enum CredentialError: LocalizedError {
    case keychainCredentialsMissing

    var errorDescription: String? {
        switch self {
        case .keychainCredentialsMissing:
            return "Username and password are not stored in Keychain"
        }
    }
}
