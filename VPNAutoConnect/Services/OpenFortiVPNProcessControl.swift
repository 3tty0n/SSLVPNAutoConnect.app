import AppKit
import Foundation

enum OpenFortiVPNProcessControl {
    static func stopManagedProcesses() {
        guard let binary = AppPaths.openfortivpnBinary() else {
            cleanupArtifacts()
            return
        }

        let configPath = AppPaths.configFile.path

        if hasManagedProcesses(binary: binary, configPath: configPath) {
            writeStopScriptIfNeeded()

            let stopScript = AppPaths.stopScript.path
            let pidPath = AppPaths.pidFile.path
            let inner = """
            /bin/bash "\(stopScript)" "\(binary)" "\(configPath)" "\(pidPath)"
            """
            runAdminShellBlocking(inner)
        }

        cleanupArtifacts()
    }

    private static func hasManagedProcesses(binary: String, configPath: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-f", "\(binary) -c \(configPath)"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        guard (try? process.run()) != nil else { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    private static func writeStopScriptIfNeeded() {
        let script = """
        #!/bin/bash
        set -u
        BINARY="$1"
        CONFIG="$2"
        PIDFILE="$3"

        PIDS=$(pgrep -f "$BINARY -c $CONFIG" 2>/dev/null || true)
        if [ -n "$PIDS" ]; then
            printf '%s\\n' "$PIDS" | xargs kill -TERM 2>/dev/null || true
            sleep 1
            PIDS=$(pgrep -f "$BINARY -c $CONFIG" 2>/dev/null || true)
            if [ -n "$PIDS" ]; then
                printf '%s\\n' "$PIDS" | xargs kill -KILL 2>/dev/null || true
            fi
        fi

        rm -f "$PIDFILE"
        rm -rf "${PIDFILE}.launch.lock"
        """

        let url = AppPaths.stopScript
        guard (try? script.write(to: url, atomically: true, encoding: .utf8)) != nil else { return }
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    private static func runAdminShellBlocking(_ command: String) {
        let escaped = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")

        let source = "do shell script \"\(escaped)\" with administrator privileges"
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
    }

    private static func cleanupArtifacts() {
        try? FileManager.default.removeItem(at: AppPaths.pidFile)
        try? FileManager.default.removeItem(at: AppPaths.configFile)
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: AppPaths.pidFile.path + ".launch.lock"))
    }
}
