import Foundation
import Darwin

final class QuotaStop: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    func cancel() { lock.lock(); stopped = true; lock.unlock() }
    func check() throws { lock.lock(); let value = stopped; lock.unlock(); if value { throw CancellationError() } }
}
// Blocking pipe I/O runs off the main actor, is bounded, and observes cancellation every 50 ms.
// Both modes isolate the child and never send a refresh token. Only explicit warmup mode can start a turn.
enum QuotaBroker {
    static func canonicalSystemURL(_ url: URL) -> URL {
        let path = url.path
        return URL(fileURLWithPath: path.hasPrefix("/var/") || path.hasPrefix("/tmp/") || path == "/tmp" || path == "/var" ? "/private" + path : path)
    }
    static func read(cli: URL, root: URL, auth: Data, expectedKey: String, timeout: TimeInterval = 30) async throws -> QuotaSnapshot {
        let credentials = try QuotaCredentials.read(auth, expectedKey: expectedKey)
        let stop = QuotaStop()
        return try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            return try await Task.detached(priority: .utility) { try query(cli: cli, root: root, credentials: credentials, stop: stop, timeout: timeout) }.value
        }, onCancel: { stop.cancel() })
    }
    static func privateDirectory(_ url: URL) throws {
        let fm = FileManager.default
        // Resolve system /var aliases, then reject links in user-controlled components.
        try checkPath(url)
        try fm.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var s = stat()
        guard lstat(url.path, &s) == 0, (s.st_mode & S_IFMT) == S_IFDIR, s.st_uid == getuid(), chmod(url.path, 0o700) == 0 else { throw SwitchError("额度查询私有目录检查失败。") }
    }
    static func checkPath(_ url: URL) throws {
        // Keep the physical system prefix, and never resolve user-controlled links.
        // Foundation can retain /var when resolving a not-yet-created leaf.
        var item = canonicalSystemURL(url)
        guard !item.pathComponents.contains("..") else { throw SwitchError("额度目录路径含父级跳转。") }
        while item.path != "/" {
            var s = stat()
            if lstat(item.path, &s) == 0 {
                guard (s.st_mode & S_IFMT) != S_IFLNK else { throw SwitchError("额度目录含符号链接，请使用本机普通目录。") }
            } else if errno != ENOENT { throw SwitchError("额度目录访问受限。") }
            item.deleteLastPathComponent()
        }
    }
    static func warmup(cli: URL, root: URL, auth: Data, expectedKey: String, reset: Date, timeout: TimeInterval = 75) async throws -> WarmupResult {
        let credentials = try QuotaCredentials.read(auth, expectedKey: expectedKey)
        let stop = QuotaStop()
        return try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            return try await Task.detached(priority: .utility) {
                guard case .warmup(let value) = try exchange(cli: cli, root: root, credentials: credentials, stop: stop, timeout: timeout, reset: reset) else { throw SwitchError("预热返回类型异常。") }
                return value
            }.value
        }, onCancel: { stop.cancel() })
    }
    static func diagnose(cli: URL, root: URL, auth: Data, expectedKey: String, timeout: TimeInterval = 45) async throws -> DiagnosticReport {
        let credentials = try QuotaCredentials.read(auth, expectedKey: expectedKey)
        let stop = QuotaStop()
        return try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            return try await Task.detached(priority: .utility) {
                guard case .diagnostic(let report) = try exchange(cli: cli, root: root, credentials: credentials, stop: stop, timeout: timeout, diagnostic: true) else { throw SwitchError("诊断结果格式异常。") }
                return report
            }.value
        }, onCancel: { stop.cancel() })
    }
    static func consumeReset(cli: URL, root: URL, auth: Data, expectedKey: String, attempt: ResetAttempt, timeout: TimeInterval = 45) async throws -> ResetOutcome {
        let credentials = try QuotaCredentials.read(auth, expectedKey: expectedKey)
        let stop = QuotaStop()
        return try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            return try await Task.detached(priority: .utility) {
                guard case .resetCard(let outcome) = try exchange(cli: cli, root: root, credentials: credentials, stop: stop, timeout: timeout, resetAttempt: attempt) else { throw SwitchError("重置结果待确认；请求标识已保留。") }
                return outcome
            }.value
        }, onCancel: { stop.cancel() })
    }
    private enum Reply { case quota(QuotaSnapshot), warmup(WarmupResult), diagnostic(DiagnosticReport), resetCard(ResetOutcome) }
    private static func query(cli: URL, root: URL, credentials: QuotaCredentials, stop: QuotaStop, timeout: TimeInterval) throws -> QuotaSnapshot {
        guard case .quota(let value) = try exchange(cli: cli, root: root, credentials: credentials, stop: stop, timeout: timeout) else { throw SwitchError("额度返回类型异常。") }
        return value
    }
    private static func exchange(cli: URL, root: URL, credentials: QuotaCredentials, stop: QuotaStop, timeout: TimeInterval, reset: Date? = nil, diagnostic: Bool = false, resetAttempt: ResetAttempt? = nil) throws -> Reply {
        try stop.check()
        let canonical = canonicalSystemURL(root)
        let parent = canonical.appendingPathComponent(resetAttempt != nil ? "reset-requests" : diagnostic ? "diagnostic-queries" : reset == nil ? "quota-queries" : "warmup-requests")
        try privateDirectory(parent)
        let dir = parent.appendingPathComponent(UUID().uuidString); try privateDirectory(dir)
        let p = Process(); let stdin = Pipe(); let stdout = Pipe()
        var started = false
        defer {
            try? stdin.fileHandleForWriting.close()
            if started && p.isRunning {
                p.terminate()
                let limit = ProcessInfo.processInfo.systemUptime + 2
                while p.isRunning && ProcessInfo.processInfo.systemUptime < limit { Thread.sleep(forTimeInterval: 0.02) }
                if p.isRunning { kill(p.processIdentifier, SIGKILL) }
                p.waitUntilExit()
            }
            try? stdout.fileHandleForReading.close()
            // Remove only our own UUID directory, never a live Codex home or another process's files.
            if (try? checkPath(dir)) != nil { try? FileManager.default.removeItem(at: dir) }
        }
        p.executableURL = cli
        p.arguments = ["-c", "cli_auth_credentials_store=\"ephemeral\"", "-c", "analytics.enabled=false", "app-server"]
        var env = ProcessInfo.processInfo.environment
        for key in ["OPENAI_API_KEY", "CODEX_API_KEY", "CODEX_ACCESS_TOKEN", "OPENAI_BASE_URL", "CODEX_THREAD_ID", "CODEX_INTERNAL_ORIGINATOR_OVERRIDE", "RUST_LOG"] { env.removeValue(forKey: key) }
        env["CODEX_HOME"] = dir.path
        if reset != nil || diagnostic || resetAttempt != nil {
            // Strict allowlist: no live HOME/config, refresh tokens, API keys, endpoint overrides or shared databases.
            let temporary = dir.appendingPathComponent("tmp"); try privateDirectory(temporary)
            env = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": dir.path, "CODEX_HOME": dir.path,
                   "CODEX_SQLITE_HOME": dir.appendingPathComponent("state").path, "TMPDIR": temporary.path,
                   "XDG_CONFIG_HOME": dir.path, "XDG_DATA_HOME": dir.path, "XDG_CACHE_HOME": dir.path,
                   "LANG": "en_US.UTF-8", "USER": NSUserName(), "LOGNAME": NSUserName()]
            p.arguments = ["-c", "cli_auth_credentials_store=\"ephemeral\"", "-c", "analytics.enabled=false",
                           "-c", "web_search=\"disabled\"", "-c", "features.shell_tool=false", "-c", "features.unified_exec=false",
                           "-c", "features.shell_snapshot=false", "-c", "features.apps=false", "-c", "features.multi_agent=false",
                           "-c", "features.js_repl=false", "-c", "features.sleep_tool=false", "-c", "features.image_generation=false", "app-server"]
        }
        p.environment = env; p.currentDirectoryURL = dir
        p.standardInput = stdin; p.standardOutput = stdout; p.standardError = FileHandle.nullDevice
        do { try p.run(); started = true } catch { throw SwitchError("官方额度组件未启动，请检查 Codex 安装。") }
        let inputFD = stdin.fileHandleForWriting.fileDescriptor; let outputFD = stdout.fileHandleForReading.fileDescriptor
        guard fcntl(inputFD, F_SETFL, fcntl(inputFD, F_GETFL) | O_NONBLOCK) != -1,
              fcntl(outputFD, F_SETFL, fcntl(outputFD, F_GETFL) | O_NONBLOCK) != -1,
              fcntl(inputFD, F_SETNOSIGPIPE, 1) != -1 else { throw SwitchError("额度组件管道初始化失败。") }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        func check() throws {
            try stop.check()
            if ProcessInfo.processInfo.systemUptime >= deadline { throw SwitchError(reset == nil ? "额度查询超时，请稍后刷新。" : "预热请求超时，结果待确认；自动重试已暂停。") }
        }
        func send(_ message: [String: Any]) throws {
            var data = try JSONSerialization.data(withJSONObject: message); data.append(0x0a)
            var offset = 0
            while offset < data.count {
                try check()
                let n = data.withUnsafeBytes { Darwin.write(inputFD, $0.baseAddress!.advanced(by: offset), data.count - offset) }
                if n > 0 { offset += n }
                else if n < 0 && (errno == EAGAIN || errno == EINTR) { var fd = pollfd(fd: inputFD, events: Int16(POLLOUT), revents: 0); _ = poll(&fd, 1, 50) }
                else { throw SwitchError("额度组件管道已关闭，请重试。") }
            }
        }
        var state = QuotaProtocol(credentials: credentials)
        var warm = reset.map { WarmupProtocol(credentials: credentials, directory: dir.path, reset: $0) }
        var diagnosticState = DiagnosticProtocol(credentials: credentials)
        var resetState = resetAttempt.map { ResetProtocol(credentials: credentials, attempt: $0) }
        try send(diagnostic ? DiagnosticProtocol.initialize : reset == nil ? QuotaProtocol.initialize : WarmupProtocol.initialize)
        var buffer = Data(); var chunk = [UInt8](repeating: 0, count: 8192)
        while true {
            try check()
            var fd = pollfd(fd: outputFD, events: Int16(POLLIN), revents: 0)
            let ready = poll(&fd, 1, 50)
            if ready < 0 { if errno == EINTR { continue }; throw SwitchError("额度组件读取失败。") }
            if ready == 0 { continue }
            let n = Darwin.read(outputFD, &chunk, chunk.count)
            if n < 0 { if errno == EAGAIN || errno == EINTR { continue }; throw SwitchError("额度组件读取失败。") }
            guard n > 0 else { throw SwitchError("额度组件已结束，请更新官方 Codex 或重试。") }
            buffer.append(contentsOf: chunk.prefix(n))
            guard buffer.count <= 2_000_000 else { throw SwitchError("额度响应过大，查询已结束。") }
            while let end = buffer.firstIndex(of: 0x0a) {
                let line = Data(buffer[..<end]); buffer.removeSubrange(...end)
                guard let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { throw SwitchError("额度响应格式异常。") }
                if resetState != nil {
                    switch try resetState!.receive(obj) {
                    case .ignore: break
                    case .send(let messages): for message in messages { try send(message) }
                    case .result(let outcome): return .resetCard(outcome)
                    }
                    continue
                }
                if diagnostic {
                    switch try diagnosticState.receive(obj) {
                    case .ignore: break
                    case .send(let messages): for message in messages { try send(message) }
                    case .result(let report): return .diagnostic(report)
                    }
                    continue
                }
                if warm != nil {
                    switch try warm!.receive(obj) {
                    case .ignore: break
                    case .send(let messages): for message in messages { try send(message) }
                    case .result(let result): return .warmup(result)
                    }
                    continue
                }
                switch try state.receive(obj) {
                case .ignore: break
                case .send(let messages): for message in messages { try send(message) }
                case .result(let snapshot): return .quota(snapshot)
                }
            }
        }
    }
}
