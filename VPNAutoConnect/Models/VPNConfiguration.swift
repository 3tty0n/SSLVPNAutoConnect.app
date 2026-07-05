import Foundation

struct VPNConfiguration: Codable, Equatable {
    var host: String = ""
    var port: Int = 443
    var trustedCert: String = ""
    var realm: String = ""
    var autoConnect: Bool = false
    var launchAtLogin: Bool = false
    var persistentInterval: Int = 15
    var setDNS: Bool = true
    var setRoutes: Bool = true

    /// Legacy field kept for migration only; credentials are not stored here.
    var username: String = ""

    static let storageKey = "VPNConfiguration"

    static func load() -> VPNConfiguration {
        guard
            let data = UserDefaults.standard.data(forKey: storageKey),
            var config = try? JSONDecoder().decode(VPNConfiguration.self, from: data)
        else {
            return VPNConfiguration()
        }

        KeychainService.migrateLegacyPasswordIfNeeded(fallbackUsername: config.username)
        config.username = ""
        return config
    }

    func save() {
        var toSave = self
        toSave.username = ""
        guard let data = try? JSONEncoder().encode(toSave) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }

    var isValid: Bool {
        !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && port > 0 && port <= 65535
            && CredentialStore.hasKeychainCredentials()
    }
}
