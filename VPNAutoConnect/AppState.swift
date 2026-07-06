import Combine
import ServiceManagement
import SwiftUI

@MainActor
final class AppState: ObservableObject {
    @Published private(set) var config: VPNConfiguration
    @Published private(set) var canConnect = false
    @Published private(set) var openfortivpnInstalled = false

    let vpnManager = VPNManager()

    private var didAttemptAutoConnect = false
    private var cancellables = Set<AnyCancellable>()

    init() {
        config = VPNConfiguration.load()
        refreshSystemStatus()
        updateCanConnect()

        vpnManager.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)
    }

    func refreshSystemStatus() {
        openfortivpnInstalled = AppPaths.openfortivpnBinary() != nil
    }

    func applySettings(
        config: VPNConfiguration,
        username: String,
        password: String
    ) {
        do {
            try saveCredentials(username: username, password: password)
            self.config = config
            config.save()
            updateLaunchAtLogin(enabled: config.launchAtLogin)
            updateCanConnect()
        } catch {
            vpnManager.reportError(error.localizedDescription)
        }
    }

    func connect() async {
        guard !vpnManager.status.isActive else { return }

        do {
            try validateCredentialsAvailable()
            config.save()
        } catch {
            vpnManager.reportError(error.localizedDescription)
            return
        }
        await vpnManager.connect(config: config)
    }

    func disconnect() async {
        await vpnManager.disconnect()
    }

    func toggleConnection() async {
        if vpnManager.status.isActive {
            await disconnect()
        } else {
            await connect()
        }
    }

    func applyAutoConnectIfNeeded() {
        guard !didAttemptAutoConnect else { return }
        didAttemptAutoConnect = true
        guard config.autoConnect, !vpnManager.status.isActive else { return }

        Task {
            await connect()
        }
    }

    func prepareForQuit() async {
        if vpnManager.status.isActive {
            await disconnect()
        }
    }

    func restartApp() async {
        await disconnect()

        let bundlePath = Bundle.main.bundlePath
        let relaunch = Process()
        relaunch.executableURL = URL(fileURLWithPath: "/bin/sh")
        relaunch.arguments = ["-c", "sleep 0.5; /usr/bin/open \"\(bundlePath)\""]

        do {
            try relaunch.run()
        } catch {
            vpnManager.reportError("Failed to restart app: \(error.localizedDescription)")
            return
        }

        NSApplication.shared.terminate(nil)
    }

    private func saveCredentials(username: String, password: String) throws {
        let user = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !user.isEmpty, !password.isEmpty else {
            if CredentialStore.hasKeychainCredentials() { return }
            throw CredentialError.keychainCredentialsMissing
        }
        try CredentialStore.save(username: user, password: password)
    }

    private func validateCredentialsAvailable() throws {
        guard CredentialStore.hasKeychainCredentials() else {
            throw CredentialError.keychainCredentialsMissing
        }
    }

    private func updateCanConnect() {
        let hostValid = !config.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && config.port > 0 && config.port <= 65535
        canConnect = hostValid && CredentialStore.hasKeychainCredentials()
    }

    private func updateLaunchAtLogin(enabled: Bool) {
        guard #available(macOS 13.0, *) else { return }

        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            // User may have denied login item permission
        }
    }
}
