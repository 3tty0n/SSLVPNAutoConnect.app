import AppKit
import Foundation

enum OpenFortiVPNProcessControl {
    private static let stopLock = NSLock()
    private static var lastStopCompletedAt: Date?

    static func hasActiveSession() -> Bool {
        if managedProcessPID() != nil {
            return true
        }
        // 状態ファイルが残っている場合のみ、ppp インターフェースを自セッションの痕跡として扱う。
        // これにより、他の VPN の ppp インターフェースを誤検知することが減る。
        if hasSavedNetworkState(), hasStalePPPInterfaces() || defaultRouteUsesPPP() {
            return true
        }
        return false
    }

    static func managedProcessPID() -> pid_t? {
        guard let binary = AppPaths.openfortivpnBinary() else { return nil }
        let configPath = AppPaths.configFile.path
        if let pid = managedProcessPID(binary: binary, configPath: configPath) {
            return pid
        }
        // フォールバック: バイナリパスが変わっても、設定ファイルパスでプロセスを探す
        return processPIDByConfigPath(configPath)
    }

    static func prepareForConnect(setDNS: Bool) {
        lastStopCompletedAt = nil
        captureNetworkState(setDNS: setDNS)
    }

    static func captureNetworkState(setDNS: Bool) {
        var lines: [String] = []

        if let route = readDefaultRoute(), !route.interface.hasPrefix("ppp") {
            lines.append("DEFAULT_IFACE=\(route.interface)")
            if let gateway = route.gateway, !gateway.isEmpty {
                lines.insert("DEFAULT_GW=\(gateway)", at: 0)
            }
        }

        let existingPpp = existingPPPInterfaceNames()
        lines.append("EXISTING_PPP_IFACES=\(existingPpp.joined(separator: ","))")
        lines.append("SET_DNS=\(setDNS ? 1 : 0)")

        let content = lines.joined(separator: "\n") + "\n"
        try? content.write(to: AppPaths.networkStateFile, atomically: true, encoding: .utf8)
    }

    static func cleanupStaleStateIfNeeded() {
        guard managedProcessPID() == nil else { return }
        guard !hasStalePPPInterfaces() else { return }
        guard !defaultRouteUsesPPP() else { return }
        cleanupArtifacts()
    }

    static func stopManagedProcesses() {
        stopLock.lock()
        defer { stopLock.unlock() }

        if let lastStopCompletedAt,
           Date().timeIntervalSince(lastStopCompletedAt) < 2 {
            return
        }

        guard let binary = AppPaths.openfortivpnBinary() else {
            // openfortivpn が見つからない場合も、保存した状態があれば復元する。
            if hasSavedNetworkState() {
                restoreNetworkIfNeeded(force: true)
            }
            cleanupArtifacts()
            lastStopCompletedAt = Date()
            return
        }

        let configPath = AppPaths.configFile.path
        let hadManagedProcesses = hasManagedProcesses(binary: binary, configPath: configPath)
        // 自セッション起因の場合のみネットワークを復元する。無関係な ppp インターフェースや
        // 他 VPN の経路を壊さないよう、ppp インターフェースの有無だけでは復元しない。
        let shouldRestore = hadManagedProcesses || hasSavedNetworkState()

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
        guard force || hasSavedNetworkState() else {
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

    private static func processPIDByConfigPath(_ configPath: String) -> pid_t? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-f", configPath]

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
            || processPIDByConfigPath(configPath) != nil
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

        if [ -f "$STATE_FILE" ]; then
            # shellcheck disable=SC1090
            source "$STATE_FILE"

            # openfortivpn 接続前に存在しなかった ppp インターフェースだけを落とす。
            # これにより、他の VPN の ppp インターフェースを誤って切断しない。
            for iface in $(ifconfig -l 2>/dev/null | tr ' ' '\\n' | grep '^ppp' || true); do
                case "${EXISTING_PPP_IFACES:-}" in
                    *"$iface"*) continue ;;
                esac
                while route -n delete default -interface "$iface" 2>/dev/null; do :; done
                ifconfig "$iface" down 2>/dev/null || true
            done

            # 保存したデフォルト経路がある場合のみ、経路を復元する。
            # 保存した経路がなければ現在の経路を触らない。
            if [ -n "${DEFAULT_GW:-}" ] || [ -n "${DEFAULT_IFACE:-}" ]; then
                route -n delete default 2>/dev/null || true
                if [ -n "${DEFAULT_GW:-}" ] && [ -n "${DEFAULT_IFACE:-}" ]; then
                    route add default "$DEFAULT_GW" -interface "$DEFAULT_IFACE" 2>/dev/null \\
                        || route add default "$DEFAULT_GW" 2>/dev/null || true
                elif [ -n "${DEFAULT_GW:-}" ]; then
                    route add default "$DEFAULT_GW" 2>/dev/null || true
                fi
            fi
        fi

        # 万が一デフォルト経路が存在しなくなった場合の安全ネット
        if ! route -n get default 2>/dev/null | grep -q 'gateway:'; then
            for iface in $(ifconfig -l 2>/dev/null | tr ' ' '\\n' | grep -E '^en[0-9]+$' || true); do
                if ifconfig "$iface" 2>/dev/null | grep -q 'status: active'; then
                    gw=$(ipconfig getoption "$iface" router 2>/dev/null || true)
                    if [ -n "$gw" ]; then
                        route add default "$gw" -interface "$iface" 2>/dev/null \\
                            || route add default "$gw" 2>/dev/null || true
                        break
                    fi
                fi
            done
        fi

        # DNS キャッシュのクリアは行うが、すべてのネットワークサービスの DNS 設定を
        # 空にするのはやめる。そうしないと他の VPN や Wi-Fi の DNS 設定まで消える。
        dscacheutil -flushcache 2>/dev/null || true
        killall -HUP mDNSResponder 2>/dev/null || true
        """

        let url = AppPaths.networkRestoreScript
        guard (try? script.write(to: url, atomically: true, encoding: .utf8)) != nil else { return }
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    private static func existingPPPInterfaceNames() -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/sbin/ifconfig")
        process.arguments = ["-l"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        guard (try? process.run()) != nil else { return [] }
        process.waitUntilExit()

        guard process.terminationStatus == 0,
              let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
        else {
            return []
        }

        return output
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { $0.hasPrefix("ppp") }
    }

    private static func hasStalePPPInterfaces() -> Bool {
        !existingPPPInterfaceNames().isEmpty
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
