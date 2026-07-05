import SwiftUI

@main
struct VPNAutoConnectApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var appState = AppState()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environmentObject(appState)
        } label: {
            MenuBarIconView(status: appState.vpnManager.status)
        }
        .menuBarExtraStyle(.menu)

        Window("SSLVPNAutoConnect Settings", id: "settings") {
            SettingsView()
                .environmentObject(appState)
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 480, height: 620)
    }
}
