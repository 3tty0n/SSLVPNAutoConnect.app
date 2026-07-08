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

            if shouldShowLastLogLine {
                Text(appState.vpnManager.lastLogLine)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Divider()

            Button("Connect") {
                Task { await appState.connect() }
            }
            .disabled(!appState.canConnect || appState.isBusy || status.isActive)

            Button("Stop") {
                Task { await appState.stop() }
            }
            .disabled(!appState.canStop || appState.isBusy)

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
            appState.refreshConnectionControls()
            appState.applyAutoConnectIfNeeded()
        }
    }

    private var shouldShowLastLogLine: Bool {
        guard !appState.vpnManager.lastLogLine.isEmpty else { return false }
        if case .connected = status { return false }
        return true
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
