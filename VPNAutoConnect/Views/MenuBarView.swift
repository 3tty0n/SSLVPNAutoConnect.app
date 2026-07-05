import AppKit
import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.openWindow) private var openWindow

    private var status: VPNStatus {
        appState.vpnManager.status
    }

    var body: some View {
        Group {
            Label(status.label, systemImage: status.menuBarSymbol)
                .font(.caption)
                .foregroundStyle(statusForegroundStyle)
                .symbolRenderingMode(.monochrome)

            if !appState.vpnManager.lastLogLine.isEmpty {
                Text(appState.vpnManager.lastLogLine)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Divider()

            Button(status.isActive ? "Disconnect" : "Connect") {
                Task { await appState.toggleConnection() }
            }
            .disabled(!appState.canConnect && !status.isActive)

            Button("Settings…") {
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: "settings")
            }

            Divider()

            Button("Restart App") {
                Task { await appState.restartApp() }
            }

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
        }
        .onAppear {
            appState.applyAutoConnectIfNeeded()
        }
    }

    private var statusForegroundStyle: AnyShapeStyle {
        switch status {
        case .disconnected:
            return AnyShapeStyle(.secondary)
        default:
            return AnyShapeStyle(.primary)
        }
    }
}
