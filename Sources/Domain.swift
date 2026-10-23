import Foundation
import CryptoKit
import Darwin

struct SwitchError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
struct Identity: Equatable {
    let key: String
    let email: String
    let plan: String
    static func read(_ data: Data) throws -> Identity {
        guard data.count < 2_000_000,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = object["tokens"] as? [String: Any],
              let idToken = tokens["id_token"] as? String,
              let access = tokens["access_token"] as? String, !access.isEmpty,
              let refresh = tokens["refresh_token"] as? String, !refresh.isEmpty else {
            throw SwitchError("请选择通过 ChatGPT 登录的 Codex 账号。此版本不切换 API Key 或临时凭据。")
        }
        let parts = idToken.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { throw SwitchError("登录资料格式不完整，请重新登录该账号。") }
        var base = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base += String(repeating: "=", count: (4 - base.count % 4) % 4)
        guard let payload = Data(base64Encoded: base), let claims = try JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let subject = claims["sub"] as? String, !subject.isEmpty else { throw SwitchError("登录资料缺少账号身份，请重新登录。") }
        let auth = claims["https://api.openai.com/auth"] as? [String: Any] ?? [:]
        guard let account = (tokens["account_id"] as? String) ?? (auth["chatgpt_account_id"] as? String), !account.isEmpty else {
            throw SwitchError("登录资料缺少工作区身份，请重新登录。")
        }
        let key = SHA256.hash(data: Data((subject + "\u{0}" + account).utf8)).map { String(format: "%02x", $0) }.joined()
        // These locally decoded labels are display metadata, not proof of server-side login validity.
        return Identity(key: key, email: claims["email"] as? String ?? "未显示邮箱", plan: auth["chatgpt_plan_type"] as? String ?? "chatgpt")
    }
}
struct SavedAccount: Codable, Identifiable, Equatable {
    var id: UUID
    var identityKey: String
    var label: String
    var email: String
    var plan: String
    var savedAt: Date
    var color: Int
}
struct SwitchLibrary: Codable {
    var version = 1
    var accounts: [SavedAccount] = []
    var appearance = "system"
    var lastSwitch: Date?
    var rollbackAvailable = false
}
struct AppPaths {
    let root: URL
    let codexHome: URL
    var auth: URL { codexHome.appendingPathComponent("auth.json") }
    var config: URL { codexHome.appendingPathComponent("config.toml") }
    var metadata: URL { root.appendingPathComponent("accounts.json") }
    static func live() -> AppPaths {
        let env = ProcessInfo.processInfo.environment
        return AppPaths(root: env["STILL_SWITCHER_DATA"].map { URL(fileURLWithPath: $0) } ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("StillCodexSwitcher"),
                        codexHome: URL(fileURLWithPath: env["CODEX_HOME"] ?? NSHomeDirectory() + "/.codex"))
    }
}
struct SecureFile {
    static func read(_ url: URL) throws -> Data? {
        var s = stat()
        if lstat(url.path, &s) != 0 { if errno == ENOENT { return nil }; throw SwitchError("读取本地文件失败，请检查目录权限。") }
        guard (s.st_mode & S_IFMT) == S_IFREG, s.st_uid == getuid() else { throw SwitchError("目标需为当前用户拥有的普通文件，链接或其他用户的文件保持原样。") }
        guard s.st_size <= 2_000_000 else { throw SwitchError("文件大小超出预期，原文件保持不变。") }
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw SwitchError("打开文件失败。") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var actual = stat()
        guard fstat(fd, &actual) == 0, (actual.st_mode & S_IFMT) == S_IFREG, actual.st_uid == getuid(), actual.st_size <= 2_000_000 else {
            throw SwitchError("读取时文件状态发生变化，请检查后重试。")
        }
        let data = try handle.readToEnd() ?? Data()
        guard data.count <= 2_000_000 else { throw SwitchError("文件大小超出预期。") }
        return data
    }
    static func write(_ data: Data, to url: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        _ = try read(url)
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".still-" + UUID().uuidString)
        let fd = open(tmp.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw SwitchError("创建临时文件失败，原文件保持不变。") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? fm.removeItem(at: tmp) }
        try handle.write(contentsOf: data); try handle.synchronize(); try handle.close()
        guard rename(tmp.path, url.path) == 0 else { throw SwitchError("原子替换未完成，原文件保持不变。") }
    }
    static func loadLibrary(_ url: URL) throws -> SwitchLibrary {
        guard let data = try read(url) else { return SwitchLibrary() }
        let value = try JSONDecoder().decode(SwitchLibrary.self, from: data)
        guard value.version == 1, Set(value.accounts.map(\.id)).count == value.accounts.count,
              Set(value.accounts.map(\.identityKey)).count == value.accounts.count else { throw SwitchError("账号列表版本或内容异常，原文件已保留。") }
        return value
    }
    static func saveLibrary(_ value: SwitchLibrary, to url: URL) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try write(encoder.encode(value), to: url)
    }
    static func checkFileMode(_ config: URL) throws {
        guard let data = try read(config), let text = String(data: data, encoding: .utf8) else { return }
        // Only the top-level setting applies here; never rewrite user configuration.
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") { break }
            if line.hasPrefix("cli_auth_credentials_store") {
                let pattern = #"^cli_auth_credentials_store\s*=\s*[\"']file[\"']\s*(#.*)?$"#
                guard line.range(of: pattern, options: .regularExpression) != nil else {
                    throw SwitchError("检测到非 file 凭据存储模式。请先确认 Codex 的存储设置；切换器保留现有配置不变。")
                }
            }
        }
    }
}
final class OperationLock {
    private var fd: Int32 = -1
    init(_ root: URL) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        fd = open(root.appendingPathComponent("operation.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard fd >= 0, flock(fd, LOCK_EX | LOCK_NB) == 0 else { if fd >= 0 { close(fd); fd = -1 }; throw SwitchError("另一个切换操作正在进行，请稍后再试。") }
    }
    deinit { if fd >= 0 { flock(fd, LOCK_UN); close(fd) } }
}
