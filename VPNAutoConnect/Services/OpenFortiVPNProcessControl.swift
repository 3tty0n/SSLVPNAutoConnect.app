import AppKit
import Foundation

enum OpenFortiVPNProcessControl {
    static func stopManagedProcesses() {
        guard let binary = AppPaths.openfortivpnBinary() else {
            cleanupArtifacts()
            return
        }

        let configPath = AppPaths.configFile.path
        let hadManagedProcesses = hasManagedProcesses(binary: binary, configPath: configPath)
        let hadStalePPPInterfaces = hasStalePPPInterfaces()

        if hadManagedProcesses {
            writeStopScriptIfNeeded()

            let stopScript = AppPaths.stopScript.path
            let pidPath = AppPaths.pidFile.path
            let restoreScript = AppPaths.networkRestoreScript.path
            let inner = """
            /bin/bash "\(stopScript)" "\(binary)" "\(configPath)" "\(pidPath)" "\(restoreScript)"
            """
            runAdminShellBlocking(inner)
        } else if hadStalePPPInterfaces {
            writeNetworkRestoreScriptIfNeeded()
            runAdminShellBlocking("/bin/bash \"\(AppPaths.networkRestoreScript.path)\"")
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
        writeNetworkRestoreScriptIfNeeded()

        let script = """
        #!/bin/bash
        set -u
        BINARY="$1"
        CONFIG="$2"
        PIDFILE="$3"
        RESTORE_SCRIPT="$4"

        PIDS=$(pgrep -f "$BINARY -c $CONFIG" 2>/dev/null || true)
        if [ -n "$PIDS" ]; then
            printf '%s\\n' "$PIDS" | xargs kill -TERM 2>/dev/null || true
            for _ in 1 2 3 4 5 6 7 8 9 10; do
                sleep 1
                PIDS=$(pgrep -f "$BINARY -c $CONFIG" 2>/dev/null || true)
                if [ -z "$PIDS" ]; then
                    break
                fi
            done
            if [ -n "$PIDS" ]; then
                printf '%s\\n' "$PIDS" | xargs kill -KILL 2>/dev/null || true
                sleep 1
            fi
        fi

        /bin/bash "$RESTORE_SCRIPT"

        rm -f "$PIDFILE"
        rm -rf "${PIDFILE}.launch.lock"
        """

        let url = AppPaths.stopScript
        guard (try? script.write(to: url, atomically: true, encoding: .utf8)) != nil else { return }
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    private static func writeNetworkRestoreScriptIfNeeded() {
        let script = """
        #!/bin/bash
        set -u

        for iface in $(ifconfig -l 2>/dev/null | tr ' ' '\\n' | grep '^ppp' || true); do
            ifconfig "$iface" down 2>/dev/null || true
        done

        networksetup -listallnetworkservices 2>/dev/null | while IFS= read -r service; do
            case "$service" in
                ""|*Marked*|*marked*) continue ;;
            esac
            networksetup -setdnsservers "$service" empty 2>/dev/null || true
        done

        dscacheutil -flushcache 2>/dev/null || true
        killall -HUP mDNSResponder 2>/dev/null || true
        """

        let url = AppPaths.networkRestoreScript
        guard (try? script.write(to: url, atomically: true, encoding: .utf8)) != nil else { return }
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    private static func hasStalePPPInterfaces() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/sbin/ifconfig")
        process.arguments = ["-l"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        guard (try? process.run()) != nil else { return false }
        process.waitUntilExit()

        guard process.terminationStatus == 0,
              let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
        else {
            return false
        }

        return output.split(separator: " ").contains { $0.hasPrefix("ppp") }
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
