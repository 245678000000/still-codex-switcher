import AppKit

/// Official Codex app-server login, with a completely separate CODEX_HOME.
/// Tokens and OAuth URLs never enter diagnostics or the account metadata file.
@MainActor final class LoginBroker {
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var buffer = Data()
    private var directory: URL?
    private var loginID: String?
    private(set) var cleaning = false
    private var timeout: Task<Void, Never>?
    private var completion: ((Result<Data, Error>) -> Void)?
    var status: ((String) -> Void)?

    func start(cli: URL, root: URL, completion: @escaping (Result<Data, Error>) -> Void) throws {
        guard process == nil, !cleaning else { throw SwitchError("一个登录窗口已在等待，请先完成或取消。") }
        // The caller holds OperationLock. Remove only our UUID-named stale login directories.
        let parent = root.appendingPathComponent("logins")
        if let entries = try? FileManager.default.contentsOfDirectory(at: parent, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]) {
            for entry in entries where UUID(uuidString: entry.lastPathComponent) != nil {
                let values = try entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                let attrs = try FileManager.default.attributesOfItem(atPath: entry.path)
                if values.isDirectory == true, values.isSymbolicLink != true, (attrs[.ownerAccountID] as? NSNumber)?.uint32Value == getuid() {
                    try FileManager.default.removeItem(at: entry)
                }
            }
        }
        let dir = root.appendingPathComponent("logins/" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        directory = dir; self.completion = completion
        let p = Process(); let stdin = Pipe(); let stdout = Pipe()
        p.executableURL = cli
        p.arguments = ["-c", "cli_auth_credentials_store=\"file\"", "app-server"]
        var env = ProcessInfo.processInfo.environment
        for key in ["OPENAI_API_KEY", "CODEX_API_KEY", "CODEX_ACCESS_TOKEN", "CODEX_THREAD_ID", "CODEX_INTERNAL_ORIGINATOR_OVERRIDE"] { env.removeValue(forKey: key) }
        env["CODEX_HOME"] = dir.path
        p.environment = env; p.currentDirectoryURL = dir
        p.standardInput = stdin; p.standardOutput = stdout; p.standardError = FileHandle.nullDevice
        input = stdin.fileHandleForWriting; output = stdout.fileHandleForReading
        process = p
        output?.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            DispatchQueue.main.async { self?.consume(data) }
        }
        p.terminationHandler = { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                guard let self, self.process != nil else { return }
                self.finish(.failure(SwitchError("登录组件已结束。请重试添加账号，当前 Codex 账号保持原样。")))
            }
        }
        do {
            try p.run()
            try send(["id": 1, "method": "initialize", "params": ["clientInfo": ["name": "still_codex_switcher", "version": "1.0.0"]]])
            status?("正在打开官方登录页面…")
            timeout = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(300)) } catch { return }
                self?.finish(.failure(SwitchError("本次登录等待已结束，请重新添加。现有账号保持原样。")))
            }
        } catch { cleanup(); self.completion = nil; throw SwitchError("启动登录组件失败，请检查 Codex 安装后重试。") }
    }
    private func send(_ value: [String: Any]) throws {
        var data = try JSONSerialization.data(withJSONObject: value); data.append(0x0a)
        try input?.write(contentsOf: data)
    }
    private func consume(_ data: Data) {
        guard process != nil else { return }
        buffer.append(data)
        guard buffer.count < 4_000_000 else { finish(.failure(SwitchError("登录组件返回异常，已结束本次登录。"))); return }
        while let end = buffer.firstIndex(of: 0x0a) {
            let line = Data(buffer[..<end]); buffer.removeSubrange(...end)
            guard let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { continue }
            handle(obj)
            if process == nil { return }
        }
    }
    private func handle(_ obj: [String: Any]) {
        if obj["error"] != nil {
            finish(.failure(SwitchError("官方登录组件报告错误。请确认网络与 Codex 版本后再试。"))); return
        }
        do {
            if obj["id"] as? Int == 1 {
                try send(["method": "initialized"])
                try send(["id": 2, "method": "account/login/start", "params": ["type": "chatgpt", "useHostedLoginSuccessPage": true, "appBrand": "codex"]])
            } else if obj["id"] as? Int == 2 {
                guard let result = obj["result"] as? [String: Any], let raw = result["authUrl"] as? String,
                      let id = result["loginId"] as? String, let url = URL(string: raw), url.scheme == "https",
                      let host = url.host?.lowercased(), Self.validLoginHost(host) else {
                    throw SwitchError("登录页面地址未通过检查，本次登录已结束。")
                }
                loginID = id
                guard NSWorkspace.shared.open(url) else { throw SwitchError("浏览器未打开，请检查默认浏览器后重试。") }
                status?("等待你在浏览器完成登录。请选要添加的账号。")
            } else if obj["method"] as? String == "account/login/completed" {
                guard let params = obj["params"] as? [String: Any], params["loginId"] as? String == loginID else { return }
                guard params["success"] as? Bool == true, let dir = directory,
                      let data = try SecureFile.read(dir.appendingPathComponent("auth.json")) else {
                    throw SwitchError("本次登录尚未成功，请重新添加。原来的账号保持不变。")
                }
                _ = try Identity.read(data)
                finish(.success(data))
            }
        } catch { finish(.failure(error)) }
    }
    static func validLoginHost(_ host: String) -> Bool {
        ["openai.com", "chatgpt.com"].contains { host == $0 || host.hasSuffix("." + $0) }
    }
    func cancel() {
        if let loginID { try? send(["id": 3, "method": "account/login/cancel", "params": ["loginId": loginID]]) }
        completion = nil; cleanup()
    }
    private func finish(_ result: Result<Data, Error>) {
        let callback = completion; completion = nil
        cleanup(); callback?(result)
    }
    private func cleanup() {
        timeout?.cancel(); timeout = nil
        output?.readabilityHandler = nil
        let child = process; process = nil
        child?.terminationHandler = nil
        try? input?.close(); input = nil
        // Only our isolated child is stopped. Never terminate the user's desktop here.
        try? output?.close(); output = nil; buffer.removeAll(); loginID = nil
        let ownDirectory = directory; directory = nil
        guard child != nil || ownDirectory != nil else { return }
        cleaning = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            if let child, child.isRunning { child.terminate(); child.waitUntilExit() }
            if let ownDirectory { try? FileManager.default.removeItem(at: ownDirectory) }
            DispatchQueue.main.async { self?.cleaning = false }
        }
    }
}
