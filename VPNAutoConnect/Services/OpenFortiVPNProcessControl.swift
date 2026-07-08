import AppKit
import Foundation

enum OpenFortiVPNProcessControl {
    private static let stopLock = NSLock()
    private static var lastStopCompletedAt: Date?

    static func hasActiveSession() -> Bool {
        managedProcessPID() != nil
            || hasStalePPPInterfaces()
            || defaultRouteUsesPPP()
            || hasSavedNetworkState()
    }

    static func managedProcessPID() -> pid_t? {
        guard let binary = AppPaths.openfortivpnBinary() else { return nil }
        return managedProcessPID(binary: binary, configPath: AppPaths.configFile.path)
    }

    static func prepareForConnect() {
        lastStopCompletedAt = nil
        captureNetworkState()
    }

    static func captureNetworkState() {
        guard let route = readDefaultRoute(), !route.interface.hasPrefix("ppp") else { return }

        var lines: [String] = ["DEFAULT_IFACE=\(route.interface)"]
        if let gateway = route.gateway, !gateway.isEmpty {
            lines.insert("DEFAULT_GW=\(gateway)", at: 0)
        }

        let content = lines.joined(separator: "\n") + "\n"
        try? content.write(to: AppPaths.networkStateFile, atomically: true, encoding: .utf8)
    }

    static func stopManagedProcesses() {
        stopLock.lock()
        defer { stopLock.unlock() }

        if let lastStopCompletedAt,
           Date().timeIntervalSince(lastStopCompletedAt) < 2 {
            return
        }

        guard let binary = AppPaths.openfortivpnBinary() else {
            restoreNetworkIfNeeded(force: true)
            cleanupArtifacts()
            lastStopCompletedAt = Date()
            return
        }

        let configPath = AppPaths.configFile.path
        let hadManagedProcesses = hasManagedProcesses(binary: binary, configPath: configPath)
        let shouldRestore = hadManagedProcesses
            || hasStalePPPInterfaces()
            || defaultRouteUsesPPP()
            || hasSavedNetworkState()

        if hadManagedProcesses {
            writeStopScriptIfNeeded()

            let stopScript = AppPaths.stopScript.path
            let pidPath = AppPaths.pidFile.path
            let restoreScript = AppPaths.networkRestoreScript.path
            let inner = """
            /bin/bash "\(stopScript)" "\(binary)" "\(configPath)" "\(pidPath)" "\(restoreScript)"
            """
            runAdminShellBlocking(inner)
        } else if shouldRestore {
            writeNetworkRestoreScriptIfNeeded()
            runAdminShellBlocking("/bin/bash \"\(AppPaths.networkRestoreScript.path)\"")
        }

        cleanupArtifacts()
        lastStopCompletedAt = Date()
    }

    private struct DefaultRoute {
        let gateway: String?
        let interface: String
    }

    private static func readDefaultRoute() -> DefaultRoute? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/route")
        process.arguments = ["-n", "get", "default"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        guard (try? process.run()) != nil else { return nil }
        process.waitUntilExit()

        guard process.terminationStatus == 0,
              let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
        else {
            return nil
        }

        var gateway: String?
        var interface: String?

        for line in output.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("gateway:") {
                gateway = trimmed.split(whereSeparator: \.isWhitespace).last.map(String.init)
            } else if trimmed.hasPrefix("interface:") {
                interface = trimmed.split(whereSeparator: \.isWhitespace).last.map(String.init)
            }
        }

        guard let interface, !interface.isEmpty else { return nil }
        return DefaultRoute(gateway: gateway, interface: interface)
    }

    static func defaultRouteUsesPPP() -> Bool {
        readDefaultRoute()?.interface.hasPrefix("ppp") == true
    }

    private static func hasSavedNetworkState() -> Bool {
        FileManager.default.fileExists(atPath: AppPaths.networkStateFile.path)
    }

    private static func restoreNetworkIfNeeded(force: Bool) {
        guard force
            || hasStalePPPInterfaces()
            || defaultRouteUsesPPP()
            || hasSavedNetworkState()
        else {
            return
        }

        writeNetworkRestoreScriptIfNeeded()
        runAdminShellBlocking("/bin/bash \"\(AppPaths.networkRestoreScript.path)\"")
    }

    private static func managedProcessPID(binary: String, configPath: String) -> pid_t? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-f", "\(binary) -c \(configPath)"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        guard (try? process.run()) != nil else { return nil }
        process.waitUntilExit()

        guard process.terminationStatus == 0,
              let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8),
              let firstLine = output.split(separator: "\n").first,
              let pid = Int32(firstLine.trimmingCharacters(in: .whitespacesAndNewlines))
        else {
            return nil
        }

        return pid_t(pid)
    }

    private static func hasManagedProcesses(binary: String, configPath: String) -> Bool {
        managedProcessPID(binary: binary, configPath: configPath) != nil
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
            for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
                sleep 1
                PIDS=$(pgrep -f "$BINARY -c $CONFIG" 2>/dev/null || true)
                if [ -z "$PIDS" ]; then
                    break
                fi
            done
            if [ -n "$PIDS" ]; then
                printf '%s\\n' "$PIDS" | xargs kill -KILL 2>/dev/null || true
                sleep 2
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
        let stateFile = AppPaths.networkStateFile.path
        let script = """
        #!/bin/bash
        set -u
        STATE_FILE="\(stateFile)"

        for iface in $(ifconfig -l 2>/dev/null | tr ' ' '\\n' | grep '^ppp' || true); do
            while route -n delete default -interface "$iface" 2>/dev/null; do :; done
            ifconfig "$iface" down 2>/dev/null || true
        done

        if route -n get default 2>/dev/null | grep -q 'interface: ppp'; then
            route -n delete default 2>/dev/null || true
        fi

        if [ -f "$STATE_FILE" ]; then
            # shellcheck disable=SC1090
            source "$STATE_FILE"
            route -n delete default 2>/dev/null || true
            if [ -n "${DEFAULT_GW:-}" ] && [ -n "${DEFAULT_IFACE:-}" ]; then
                route add default "$DEFAULT_GW" -interface "$DEFAULT_IFACE" 2>/dev/null \
                    || route add default "$DEFAULT_GW" 2>/dev/null || true
            elif [ -n "${DEFAULT_GW:-}" ]; then
                route add default "$DEFAULT_GW" 2>/dev/null || true
            fi
        fi

        if ! route -n get default 2>/dev/null | grep -q 'gateway:'; then
            for iface in $(ifconfig -l 2>/dev/null | tr ' ' '\\n' | grep -E '^en[0-9]+$' || true); do
                if ifconfig "$iface" 2>/dev/null | grep -q 'status: active'; then
                    gw=$(ipconfig getoption "$iface" router 2>/dev/null || true)
                    if [ -n "$gw" ]; then
                        route add default "$gw" -interface "$iface" 2>/dev/null \
                            || route add default "$gw" 2>/dev/null || true
                        break
                    fi
                fi
            done
        fi

        networksetup -listallnetworkservices 2>/dev/null | while IFS= read -r service; do
            case "$service" in
                ""|*Marked*|*marked*) continue ;;
            esac
            networksetup -setdnsservers "$service" Empty 2>/dev/null || true
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
        try? FileManager.default.removeItem(at: AppPaths.networkStateFile)
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: AppPaths.pidFile.path + ".launch.lock"))
    }
}
