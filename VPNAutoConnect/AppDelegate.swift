import AppKit

@MainActor
enum AppLifecycle {
    weak static var appState: AppState?
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task { @MainActor in
            if let appState = AppLifecycle.appState {
                await appState.prepareForQuit()
            } else {
                OpenFortiVPNProcessControl.stopManagedProcesses()
            }
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        OpenFortiVPNProcessControl.stopManagedProcesses()
    }
}
