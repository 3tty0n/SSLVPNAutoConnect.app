import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillTerminate(_ notification: Notification) {
        OpenFortiVPNProcessControl.stopManagedProcesses()
    }
}
