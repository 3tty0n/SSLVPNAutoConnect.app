import Foundation

enum AppPaths {
    static let bundleIdentifier = "com.3tty0n.vpn-auto-connect"
    private static let supportDirectoryName = "SSLVPNAutoConnect"
    private static let legacySupportDirectoryNames = ["VPNSSLAutoConnect", "VPNAutoConnect"]

    static let openfortivpnBinaryPath: String? = resolveExecutable([
        "/opt/homebrew/bin/openfortivpn",
        "/usr/local/bin/openfortivpn",
        "/opt/local/bin/openfortivpn",
    ])

    static var applicationSupport: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent(supportDirectoryName, isDirectory: true)
        migrateLegacySupportDirectoryIfNeeded(to: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static var configFile: URL {
        applicationSupport.appendingPathComponent("openfortivpn.conf")
    }

    static var logFile: URL {
        applicationSupport.appendingPathComponent("openfortivpn.log")
    }

    static var pidFile: URL {
        applicationSupport.appendingPathComponent("openfortivpn.pid")
    }

    static var launchScript: URL {
        applicationSupport.appendingPathComponent("launch-openfortivpn.sh")
    }

    static var stopScript: URL {
        applicationSupport.appendingPathComponent("stop-openfortivpn.sh")
    }

    static var networkRestoreScript: URL {
        applicationSupport.appendingPathComponent("restore-network.sh")
    }

    static var networkStateFile: URL {
        applicationSupport.appendingPathComponent("network-state.env")
    }

    static func openfortivpnBinary() -> String? {
        openfortivpnBinaryPath
    }

    private static func migrateLegacySupportDirectoryIfNeeded(to destination: URL) {
        guard !FileManager.default.fileExists(atPath: destination.path) else { return }

        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!

        for legacyName in legacySupportDirectoryNames {
            let legacy = base.appendingPathComponent(legacyName, isDirectory: true)
            guard legacy.path != destination.path else { continue }
            guard FileManager.default.fileExists(atPath: legacy.path) else { continue }

            try? FileManager.default.moveItem(at: legacy, to: destination)
            return
        }
    }

    private static func resolveExecutable(_ candidates: [String]) -> String? {
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        return nil
    }
}
