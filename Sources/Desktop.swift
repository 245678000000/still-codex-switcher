import AppKit
import CryptoKit

@MainActor struct CodexDesktop {
    let url: URL
    var bundleID: String { Bundle(url: url)?.bundleIdentifier ?? "com.openai.codex" }
    var version: String { Bundle(url: url)?.infoDictionary?["CFBundleShortVersionString"] as? String ?? "未知" }
    var cli: URL? {
        let candidates = ["Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex", "Contents/Resources/codex"]
        return candidates.map { url.appendingPathComponent($0) }.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }
    static func find() -> CodexDesktop? {
        if let running = NSRunningApplication.runningApplications(withBundleIdentifier: "com.openai.codex").first?.bundleURL { return CodexDesktop(url: running) }
        if let installed = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.codex") { return CodexDesktop(url: installed) }
        return nil
    }
    var running: Bool { !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty }
    func quitGracefully(progress: (String) -> Void) async throws {
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        for app in apps { guard app.terminate() else { throw SwitchError("Codex 暂未接受退出请求。请保存任务并手动退出后重试。") } }
        progress("等待 Codex 完成退出…")
        for _ in 0..<100 {
            if apps.allSatisfy(\.isTerminated) { break }
            try await Task.sleep(for: .milliseconds(200))
        }
        guard apps.allSatisfy(\.isTerminated) else { throw SwitchError("Codex 仍在运行；当前账号保持不变。请完成退出提示后重试。") }
        // Wait for app-owned CLI helpers too. No force-kill and no changes to other CLI sessions.
        for _ in 0..<40 {
            if !helpersRunning() { return }
            try await Task.sleep(for: .milliseconds(200))
        }
        throw SwitchError("Codex 后台组件尚未退出；当前登录文件保持不变。请稍后重试。")
    }
    private func helpersRunning() -> Bool {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/ps"); p.arguments = ["-axo", "comm="]
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
        do { try p.run(); let data = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit(); guard p.terminationStatus == 0 else { return true }
            let prefix = url.path + "/Contents/Resources/codex-cli/"
            return (String(data: data, encoding: .utf8) ?? "").components(separatedBy: .newlines).contains { $0.hasPrefix(prefix) }
        } catch { return true }
    }
    func launch() async throws {
        let config = NSWorkspace.OpenConfiguration(); config.activates = true
        _ = try await NSWorkspace.shared.openApplication(at: url, configuration: config)
    }
}

@MainActor struct SwitchTransaction {
    let authURL: URL
    let vault: SecretVault
    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    func replace(with target: Data, start: () async throws -> Void) async throws {
        _ = try Identity.read(target)
        let original = try SecureFile.read(authURL)
        if let original { _ = try Identity.read(original) }
        // Durable rollback is written before any change to the live login file.
        let rollback = Rollback(original: original, targetDigest: Self.digest(target), date: Date())
        try vault.put(JSONEncoder().encode(rollback), for: "rollback")
        guard try SecureFile.read(authURL) == original else { throw SwitchError("备份期间登录文件发生变化，已保留当前状态。请结束其他 Codex 会话后重试。") }
        try SecureFile.write(target, to: authURL)
        do { try await start() }
        catch {
            let current = try SecureFile.read(authURL)
            guard current == target else { throw SwitchError("启动未完成，且登录文件又有变化。已保留回滚备份，请先核对当前状态。") }
            if let original { try SecureFile.write(original, to: authURL) }
            else { try FileManager.default.removeItem(at: authURL) }
            throw SwitchError("Codex 启动未完成，已恢复原来的登录文件。请手动打开 Codex。")
        }
    }
}
