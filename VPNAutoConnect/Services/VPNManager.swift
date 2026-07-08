import AppKit
import Combine
import Foundation

enum VPNErrorKind: Equatable {
    case general
    case launchFailed
    case connectionFailed
    case abnormalTermination
}

enum VPNStatus: Equatable {
    case disconnected
    case connecting
    case running
    case connected
    case disconnecting
    case error(String, kind: VPNErrorKind)

    var label: String {
        switch self {
        case .disconnected: return "Disconnected"
        case .connecting: return "Connecting…"
        case .running: return "openfortivpn running"
        case .connected: return "Connected"
        case .disconnecting: return "Disconnecting…"
        case .error(let message, let kind):
            switch kind {
            case .abnormalTermination: return "Stopped unexpectedly: \(message)"
            case .launchFailed: return "Failed to start: \(message)"
            default: return "Error: \(message)"
            }
        }
    }

    var isActive: Bool {
        switch self {
        case .connecting, .running, .connected, .disconnecting: return true
        default: return false
        }
    }

    var menuBarSymbol: String {
        switch self {
        case .disconnected: return "lock.shield"
        case .connecting, .disconnecting: return "arrow.triangle.2.circlepath"
        case .running: return "antenna.radiowaves.left.and.right"
        case .connected: return "lock.shield.fill"
        case .error(_, let kind):
            switch kind {
            case .launchFailed: return "xmark.circle.fill"
            case .abnormalTermination: return "exclamationmark.octagon.fill"
            case .connectionFailed: return "wifi.exclamationmark"
            case .general: return "exclamationmark.triangle.fill"
            }
        }
    }
}

@MainActor
final class VPNManager: ObservableObject {
    @Published private(set) var status: VPNStatus = .disconnected
    @Published private(set) var lastLogLine: String = ""

    private var monitorTask: Task<Void, Never>?
    private var connectOperation: Task<Void, Never>?

    func reportError(_ message: String, kind: VPNErrorKind = .general) {
        status = .error(message, kind: kind)
    }

    func connect(config: VPNConfiguration) async {
        if let connectOperation {
            await connectOperation.value
            return
        }

        let operation = Task { @MainActor in
            await self.performConnect(config: config)
        }
        connectOperation = operation
        defer { connectOperation = nil }
        await operation.value
    }

    private func performConnect(config: VPNConfiguration) async {
        guard config.isValid else {
            status = .error("Check VPN settings and credentials", kind: .general)
            return
        }

        let credentials: Credentials
        do {
            credentials = try CredentialStore.resolve()
        } catch {
            status = .error(error.localizedDescription, kind: .general)
            return
        }

        guard credentials.isValid else {
            status = .error("Invalid credentials", kind: .general)
            return
        }

        guard let binary = AppPaths.openfortivpnBinary() else {
            status = .error("openfortivpn not found. Install with: brew install openfortivpn", kind: .general)
            return
        }

        switch status {
        case .running, .connected:
            applyConnectionStatusFromLog()
            startMonitoring()
            return
        case .connecting:
            return
        case .disconnecting:
            return
        default:
            break
        }

        if status.isActive {
            await disconnect()
        }

        status = .connecting

        do {
            let configPath = try ConfigWriter.write(config: config, credentials: credentials)

            if let existingPID = findRunningOpenFortiVPNPID(binary: binary, configPath: configPath.path),
               isProcessRunning(pid: existingPID) {
                try String(existingPID).write(to: AppPaths.pidFile, atomically: true, encoding: .utf8)
                status = .running
                applyConnectionStatusFromLog()
                startMonitoring()
                return
            }

            OpenFortiVPNProcessControl.prepareForConnect(setDNS: config.setDNS)

            try? FileManager.default.removeItem(at: AppPaths.logFile)
            try await launchOpenFortiVPN(binary: binary, configPath: configPath.path)
            status = .running
            applyConnectionStatusFromLog()
            startMonitoring()
        } catch let error as VPNError {
            status = .error(error.localizedDescription ?? "Unknown error", kind: error.errorKind)
            ConfigWriter.removeConfig()
        } catch {
            status = .error(error.localizedDescription, kind: .general)
            ConfigWriter.removeConfig()
        }
    }

    func disconnect() async {
        let wasActive = status.isActive

        monitorTask?.cancel()
        monitorTask = nil
        connectOperation?.cancel()
        connectOperation = nil

        if wasActive {
            status = .disconnecting
        }

        await terminateOpenFortiVPN()
        status = .disconnected
        lastLogLine = ""
    }

    func syncExistingSessionIfNeeded() {
        if status.isActive {
            if monitorTask == nil {
                ensurePIDFileRecorded()
                startMonitoring()
            }
            return
        }

        guard OpenFortiVPNProcessControl.hasActiveSession() else {
            // 有効なセッションが検出できなければ、クラッシュ等で残った古い状態ファイルを消す。
            OpenFortiVPNProcessControl.cleanupStaleStateIfNeeded()
            return
        }

        ensurePIDFileRecorded()
        status = .running
        applyConnectionStatusFromLog()
        if case .running = status, OpenFortiVPNProcessControl.defaultRouteUsesPPP() {
            status = .connected
        }
        startMonitoring()
    }

    private func ensurePIDFileRecorded() {
        guard let pid = OpenFortiVPNProcessControl.managedProcessPID(),
              isProcessRunning(pid: pid)
        else {
            return
        }

        try? String(pid).write(to: AppPaths.pidFile, atomically: true, encoding: .utf8)
    }

    // MARK: - Process management

    private func launchOpenFortiVPN(binary: String, configPath: String) async throws {
        try writeLaunchScript()

        let launchScript = AppPaths.launchScript.path
        let logPath = AppPaths.logFile.path
        let pidPath = AppPaths.pidFile.path

        let inner = """
        /bin/bash "\(launchScript)" "\(binary)" "\(configPath)" "\(logPath)" "\(pidPath)"
        """

        let script = "do shell script \"\(escapeForAppleScriptShell(inner))\" with administrator privileges"

        try await runAppleScript(script)

        for _ in 0..<10 {
            if let pid = readPID(), isProcessRunning(pid: pid) {
                return
            }
            if let pid = findRunningOpenFortiVPNPID(binary: binary, configPath: configPath) {
                try? String(pid).write(to: AppPaths.pidFile, atomically: true, encoding: .utf8)
                return
            }
            try await Task.sleep(nanoseconds: 500_000_000)
        }

        let logHint = readRecentLog()
        throw VPNError.launchFailed(logHint)
    }

    private func writeLaunchScript() throws {
        let script = """
        #!/bin/bash
        set -u
        BINARY="$1"
        CONFIG="$2"
        LOG="$3"
        PIDFILE="$4"

        LOCKDIR="${PIDFILE}.launch.lock"
        if ! mkdir "$LOCKDIR" 2>/dev/null; then
            for _ in 1 2 3 4 5 6 7 8 9 10; do
                sleep 0.5
                if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
                    exit 0
                fi
                if FOUND=$(pgrep -f "$BINARY -c $CONFIG" 2>/dev/null | head -1); then
                    echo "$FOUND" > "$PIDFILE"
                    exit 0
                fi
            done
            exit 0
        fi
        trap 'rmdir "$LOCKDIR" 2>/dev/null' EXIT

        PIDS=$(pgrep -f "$BINARY -c $CONFIG" 2>/dev/null || true)
        if [ -n "$PIDS" ]; then
            PID_COUNT=$(printf '%s\n' "$PIDS" | sed '/^$/d' | wc -l | tr -d ' ')
            if [ "$PID_COUNT" -eq 1 ]; then
                printf '%s\n' "$PIDS" | head -1 > "$PIDFILE"
                exit 0
            fi
            printf '%s\n' "$PIDS" | xargs kill -TERM 2>/dev/null || true
            sleep 1
        fi

        rm -f "$PIDFILE"
        "$BINARY" -c "$CONFIG" >> "$LOG" 2>&1 < /dev/null &
        echo $! > "$PIDFILE"
        disown

        for _ in 1 2 3 4 5; do
            sleep 0.5
            if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
                exit 0
            fi
            if FOUND=$(pgrep -f "$BINARY -c $CONFIG" 2>/dev/null | head -1); then
                echo "$FOUND" > "$PIDFILE"
                exit 0
            fi
        done
        exit 0
        """

        let url = AppPaths.launchScript
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    private func findRunningOpenFortiVPNPID(binary: String, configPath: String) -> pid_t? {
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

    private func escapeForAppleScriptShell(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private func terminateOpenFortiVPN() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                OpenFortiVPNProcessControl.stopManagedProcesses()
                continuation.resume()
            }
        }
    }

    private func runAppleScript(_ source: String) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                var error: NSDictionary?
                let appleScript = NSAppleScript(source: source)
                appleScript?.executeAndReturnError(&error)

                if let error {
                    let message = (error[NSAppleScript.errorMessage] as? String) ?? "Unknown AppleScript error"
                    continuation.resume(throwing: VPNError.adminAuthFailed(message))
                } else {
                    continuation.resume()
                }
            }
        }
    }

    // MARK: - Monitoring

    private struct LogSnapshot {
        let lastLogLine: String
        let status: VPNStatus
    }

    private func startMonitoring() {
        monitorTask?.cancel()
        let logURL = AppPaths.logFile
        let pidURL = AppPaths.pidFile

        monitorTask = Task.detached(priority: .utility) { [weak self] in
            var offset: UInt64 = 0

            for pass in 0..<60 {
                if Task.isCancelled { return }
                if pass > 0 {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                }

                let snapshot = Self.readLogSnapshot(
                    logURL: logURL,
                    offset: &offset,
                    currentStatus: await self?.status ?? .connecting
                )

                if let snapshot {
                    await self?.applySnapshot(snapshot)
                    if case .connected = snapshot.status { break }
                    if case .error = snapshot.status {
                        let processAlive = Self.isVPNProcessAlive(pidURL: pidURL)
                        // プロセスが生きていれば、一時的なログの ERROR 行でも監視を続ける。
                        if processAlive {
                            continue
                        }
                        return
                    }
                }
            }

            var consecutiveDeadCount = 0

            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_000_000_000)

                if !Self.isVPNProcessAlive(pidURL: pidURL) {
                    consecutiveDeadCount += 1

                    // 初回の dead は一時的な pgrep 失敗の可能性があるので、数回リトライする。
                    if consecutiveDeadCount < 3 {
                        continue
                    }

                    if OpenFortiVPNProcessControl.hasActiveSession() {
                        await self?.recoverTrackedSession()
                        consecutiveDeadCount = 0
                        continue
                    }

                    let snapshot = Self.readLogSnapshot(
                        logURL: logURL,
                        offset: &offset,
                        currentStatus: await self?.status ?? .disconnected
                    )
                    if let snapshot {
                        await self?.applySnapshot(snapshot)
                    }

                    await MainActor.run {
                        guard let self else { return }
                        let message = self.lastLogLine.isEmpty ? "openfortivpn exited" : self.lastLogLine
                        switch self.status {
                        case .connected:
                            self.status = .error(message, kind: .abnormalTermination)
                        case .connecting, .running:
                            self.status = .error(
                                self.lastLogLine.isEmpty ? "Connection failed" : self.lastLogLine,
                                kind: .connectionFailed
                            )
                        default:
                            break
                        }
                        ConfigWriter.removeConfig()
                    }
                    return
                }

                consecutiveDeadCount = 0

                if let snapshot = Self.readLogSnapshot(
                    logURL: logURL,
                    offset: &offset,
                    currentStatus: await self?.status ?? .disconnected
                ) {
                    await self?.applySnapshot(snapshot)
                }
            }
        }
    }

    private func recoverTrackedSession() {
        ensurePIDFileRecorded()
        applyConnectionStatusFromLog()
        if case .running = status, OpenFortiVPNProcessControl.defaultRouteUsesPPP() {
            status = .connected
        }
    }

    private func applySnapshot(_ snapshot: LogSnapshot) {
        if snapshot.status != status {
            if case .connected = status, case .error = snapshot.status {
                return
            }
            status = snapshot.status
            if case .connected = snapshot.status {
                lastLogLine = ""
                return
            }
        }

        if !snapshot.lastLogLine.isEmpty, snapshot.lastLogLine != lastLogLine {
            if case .connected = status { return }
            lastLogLine = snapshot.lastLogLine
        }
    }

    private func applyConnectionStatusFromLog() {
        guard let snapshot = Self.readFullLogSnapshot(logURL: AppPaths.logFile) else { return }
        applySnapshot(snapshot)
    }

    nonisolated private static let ignorableErrorFragments = [
        "Can't assign requested address",
    ]

    nonisolated private static func isIgnorableOpenFortiVPNError(_ message: String) -> Bool {
        ignorableErrorFragments.contains { message.localizedCaseInsensitiveContains($0) }
    }

    nonisolated private static func extractErrorMessage(from line: String) -> String {
        if let range = line.range(of: "ERROR:") {
            return String(line[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return line.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated private static func isPositiveLogLine(_ line: String) -> Bool {
        isTunnelConnectedLogLine(line) || line.hasPrefix("INFO:")
    }

    nonisolated private static func isTunnelConnectedLogLine(_ line: String) -> Bool {
        line.localizedCaseInsensitiveContains("Tunnel is up and running")
            || line.localizedCaseInsensitiveContains("Interface ppp")
            || line.localizedCaseInsensitiveContains("Negotiation complete")
    }

    nonisolated private static func readFullLogSnapshot(logURL: URL) -> LogSnapshot? {
        guard
            let content = try? String(contentsOf: logURL, encoding: .utf8),
            !content.isEmpty
        else {
            return nil
        }

        return parseLogSnapshot(from: content, currentStatus: .running)
    }

    nonisolated private static func parseLogSnapshot(
        from text: String,
        currentStatus: VPNStatus
    ) -> LogSnapshot {
        var lastLogLine = ""
        var status = currentStatus

        for line in text.components(separatedBy: .newlines) where !line.isEmpty {
            if isTunnelConnectedLogLine(line) {
                status = .connected
                lastLogLine = line
                continue
            }

            if line.contains("ERROR:") || line.contains("error:") {
                let message = extractErrorMessage(from: line)

                if isIgnorableOpenFortiVPNError(message) {
                    continue
                }

                if case .connected = status {
                    continue
                }

                lastLogLine = line
                let kind: VPNErrorKind = switch currentStatus {
                case .connected: .abnormalTermination
                case .connecting, .running: .connectionFailed
                default: .general
                }
                status = .error(message, kind: kind)
                continue
            }

            if isPositiveLogLine(line) {
                lastLogLine = line
            }
        }

        return LogSnapshot(lastLogLine: lastLogLine, status: status)
    }

    nonisolated private static func readLogSnapshot(
        logURL: URL,
        offset: inout UInt64,
        currentStatus: VPNStatus
    ) -> LogSnapshot? {
        guard let handle = try? FileHandle(forReadingFrom: logURL) else { return nil }
        defer { try? handle.close() }

        handle.seek(toFileOffset: offset)
        let data = handle.readDataToEndOfFile()
        offset = handle.offsetInFile

        guard let text = String(data: data, encoding: .utf8), !text.isEmpty else {
            return nil
        }

        return parseLogSnapshot(from: text, currentStatus: currentStatus)
    }

    nonisolated private static func isVPNProcessAlive(pidURL: URL) -> Bool {
        if let content = try? String(contentsOf: pidURL, encoding: .utf8),
           let pid = Int32(content.trimmingCharacters(in: .whitespacesAndNewlines)),
           kill(pid_t(pid), 0) == 0 {
            return true
        }

        guard let pid = OpenFortiVPNProcessControl.managedProcessPID(),
              kill(pid, 0) == 0
        else {
            return false
        }

        try? String(pid).write(to: pidURL, atomically: true, encoding: .utf8)
        return true
    }

    private func readRecentLog() -> String {
        guard let content = try? String(contentsOf: AppPaths.logFile, encoding: .utf8) else {
            return ""
        }
        return content.components(separatedBy: .newlines).suffix(5).joined(separator: "\n")
    }

    private func readPID() -> pid_t? {
        guard
            let content = try? String(contentsOf: AppPaths.pidFile, encoding: .utf8),
            let pid = Int32(content.trimmingCharacters(in: .whitespacesAndNewlines))
        else {
            return nil
        }
        return pid_t(pid)
    }

    private func isProcessRunning(pid: pid_t) -> Bool {
        kill(pid, 0) == 0
    }
}

enum VPNError: LocalizedError {
    case launchFailed(String)
    case adminAuthFailed(String)

    var errorKind: VPNErrorKind {
        switch self {
        case .launchFailed: return .launchFailed
        case .adminAuthFailed: return .general
        }
    }

    var errorDescription: String? {
        switch self {
        case .launchFailed(let log):
            if log.isEmpty {
                return "Failed to start openfortivpn. Check settings and try again."
            }
            return "Failed to start openfortivpn:\n\(log)"
        case .adminAuthFailed(let message):
            return message
        }
    }
}
