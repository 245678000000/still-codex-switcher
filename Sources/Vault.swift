import CryptoKit
import Foundation
import Security

protocol SecretVault {
    func put(_ data: Data, for key: String) throws
    func get(_ key: String) throws -> Data?
    func remove(_ key: String) throws
}

/// Runs /usr/bin/security. Secrets only ever travel over stdin and stdout, never as arguments.
enum SecurityTool {
    static let itemNotFound: Int32 = 44
    static func run(_ arguments: [String], input: Data? = nil) -> (status: Int32, output: Data)? {
        let process = Process(); let stdout = Pipe(); let stdin = input.map { _ in Pipe() }
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = arguments
        process.standardInput = stdin ?? FileHandle.nullDevice
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        if let input, let stdin {
            let handle = stdin.fileHandleForWriting
            _ = fcntl(handle.fileDescriptor, F_SETNOSIGPIPE, 1)
            try? handle.write(contentsOf: input); try? handle.close()
        }
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, output)
    }
    static func base64Secret(_ output: Data) -> Data? {
        Data(base64Encoded: String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }
    static func denied(_ status: Int32?) -> SwitchError {
        SwitchError("钥匙串操作未完成（\(status.map(String.init) ?? "无法启动")）。如出现系统确认，请选择允许。")
    }
}

enum VaultInteraction { case silent, userInitiated }
struct VaultLockedError: LocalizedError {
    var errorDescription: String? { "登录资料待解锁 · 请点击「解锁登录」，后台不会弹出密码框。" }
}
protocol VaultKeyStore {
    func load() throws -> Data?
    func create(_ key: Data) throws
    func load(interaction: VaultInteraction) throws -> Data?
    func create(_ key: Data, interaction: VaultInteraction) throws
}
extension VaultKeyStore {
    func load(interaction: VaultInteraction) throws -> Data? { try load() }
    func create(_ key: Data, interaction: VaultInteraction) throws { try create(key) }
}
/// Native Security calls, scoped to one item. No CLI trust expansion or global interaction flag.
enum NativeKeychain {
    static func query(service: String, account: String, interaction: VaultInteraction = .silent) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: account, kSecAttrSynchronizable as String: false,
         // Retained for the legacy file-based Keychain ACLs migrated from older releases.
         kSecUseAuthenticationUI as String: interaction == .silent ? kSecUseAuthenticationUIFail : kSecUseAuthenticationUIAllow]
    }
    static func error(_ status: OSStatus) -> Error {
        if [errSecInteractionNotAllowed, errSecAuthFailed, errSecUserCanceled].contains(status) { return VaultLockedError() }
        return SwitchError("钥匙串操作未完成（\(status)），登录资料已保留。")
    }
    static func read(service: String, account: String, interaction: VaultInteraction) throws -> Data? {
        var q = query(service: service, account: account, interaction: interaction)
        q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?; let status = SecItemCopyMatching(q as CFDictionary, &value)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = value as? Data else { throw error(status) }
        return data
    }
}

/// Same service and Base64 format as 1.7, read natively. Existing encrypted files stay compatible.
/// Newly created items trust this application, not the general-purpose security command.
struct SecurityToolKeyStore: VaultKeyStore {
    static let account = "master"
    let service: String
    init(service: String = "app.local.still.codex-switcher.vault-key") { self.service = service }
    func load() throws -> Data? { try load(interaction: .silent) }
    func load(interaction: VaultInteraction) throws -> Data? {
        guard let data = try NativeKeychain.read(service: service, account: Self.account, interaction: interaction) else { return nil }
        guard let key = SecurityTool.base64Secret(data), key.count == 32 else { throw SwitchError("加密密钥格式异常，原数据已保留。") }
        return key
    }
    func create(_ key: Data) throws { try create(key, interaction: .silent) }
    func create(_ key: Data, interaction: VaultInteraction) throws {
        var q = NativeKeychain.query(service: service, account: Self.account, interaction: interaction)
        q[kSecValueData as String] = Data(key.base64EncodedString().utf8)
        q[kSecAttrLabel as String] = "栖言 Codex 账号 · 保存登录的加密密钥"
        let result = SecItemAdd(q as CFDictionary, nil)
        guard result == errSecSuccess || result == errSecDuplicateItem else { throw NativeKeychain.error(result) }
    }
}

protocol LegacyCredentialStore {
    func read(_ key: String) throws -> Data?
    func delete(_ key: String) throws
    func read(_ key: String, interaction: VaultInteraction) throws -> Data?
}
extension LegacyCredentialStore {
    func read(_ key: String, interaction: VaultInteraction) throws -> Data? { try read(key) }
}

/// Earlier versions kept each credential in its own Keychain item. These are only read to move them.
struct LegacyKeychain: LegacyCredentialStore {
    static let live = [
        LegacyKeychain(service: "app.local.still.codex-switcher.credentials.shared", encoded: true),
        LegacyKeychain(service: "app.local.still.codex-switcher.credentials", encoded: false)
    ]
    let service: String
    /// Both old formats use native reads. No background read permits authentication UI.
    let encoded: Bool
    private func query(_ key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: key, kSecAttrSynchronizable as String: false]
    }
    func read(_ key: String) throws -> Data? { try read(key, interaction: .silent) }
    func read(_ key: String, interaction: VaultInteraction) throws -> Data? {
        guard let data = try NativeKeychain.read(service: service, account: key, interaction: interaction) else { return nil }
        if !encoded { return data }
        guard let decoded = SecurityTool.base64Secret(data) else { throw SwitchError("旧登录备份格式异常，已保留原项目。") }
        return decoded
    }
    func delete(_ key: String) throws {
        let status = SecItemDelete(NativeKeychain.query(service: service, account: key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw NativeKeychain.error(status) }
    }
}

/// Stores each credential as an AES-GCM sealed 0600 file; the key lives in the Keychain.
/// The file name is authenticated too, so one account's file cannot stand in for another's.
final class EncryptedFileVault: SecretVault, @unchecked Sendable {
    private let directory: URL
    private let keys: VaultKeyStore
    private let legacy: [LegacyCredentialStore]
    private let lock = NSLock()
    private let cacheLifetime: TimeInterval
    private var cachedKey: SymmetricKey?
    private var cachedAt: TimeInterval = 0
    private var cacheExpiry: DispatchWorkItem?
    private var cacheGeneration = UUID()
    private var interaction: VaultInteraction = .silent // only changed while holding lock
    func clearCachedSecrets() {
        lock.withLock { cachedKey = nil; cachedAt = 0; cacheGeneration = UUID(); cacheExpiry?.cancel(); cacheExpiry = nil }
    }
    /// The only interactive path. Called on a worker after a deliberate user action.
    func unlock(_ names: [String]) throws {
        try lock.withLock {
            interaction = .userInitiated
            defer { interaction = .silent }
            _ = try symmetricKey()
            for name in names {
                if try readFile(name) != nil { continue }
                for store in legacy {
                    if let value = try store.read(name, interaction: .userInitiated) { migrate(value, for: name); break }
                }
            }
        }
    }

    init(directory: URL, keys: VaultKeyStore = SecurityToolKeyStore(), legacy: [LegacyCredentialStore] = LegacyKeychain.live, cacheLifetime: TimeInterval = 300) {
        self.directory = directory; self.keys = keys; self.legacy = legacy; self.cacheLifetime = cacheLifetime
    }
    func put(_ data: Data, for key: String) throws {
        try lock.withLock {
            let existed = FileManager.default.fileExists(atPath: try fileURL(key).path)
            try writeFile(data, for: key)
            // Cleanup only after the first verified write, not every routine update.
            if !existed, try readFile(key) == data {
                for store in legacy { try? store.delete(key) }
            }
        }
    }
    func get(_ key: String) throws -> Data? {
        try lock.withLock {
            if let stored = try readFile(key) { return stored }
            for store in legacy {
                guard let value = try store.read(key, interaction: interaction) else { continue }
                migrate(value, for: key)
                return value
            }
            return nil
        }
    }
    func remove(_ key: String) throws {
        try lock.withLock {
            let url = try fileURL(key)
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            for store in legacy { try store.delete(key) }
        }
    }
    /// The Keychain copies go only after the new file reads back identically. If anything fails they stay,
    /// and the next read simply tries again.
    private func migrate(_ value: Data, for key: String) {
        guard (try? writeFile(value, for: key)) != nil, (try? readFile(key)) == value else { return }
        for store in legacy { try? store.delete(key) }
    }
    private func fileURL(_ key: String) throws -> URL {
        guard key.range(of: "^[A-Za-z0-9-]+$", options: .regularExpression) != nil else { throw SwitchError("凭据名称不符合预期。") }
        return directory.appendingPathComponent(key + ".vault")
    }
    private func writeFile(_ data: Data, for key: String) throws {
        let url = try fileURL(key)
        let sealed = try AES.GCM.seal(data, using: try symmetricKey(), authenticating: Data(key.utf8))
        guard let combined = sealed.combined else { throw SwitchError("加密保存的登录失败。") }
        try SecureFile.write(combined, to: url)
    }
    private func readFile(_ key: String) throws -> Data? {
        guard let combined = try SecureFile.read(try fileURL(key)) else { return nil }
        // Preserve a locked-vault result; it is not encrypted-file corruption.
        let secret = try symmetricKey()
        do {
            return try AES.GCM.open(try AES.GCM.SealedBox(combined: combined), using: secret, authenticating: Data(key.utf8))
        } catch let error as SwitchError { throw error }
        catch { throw SwitchError("保存的登录无法解密，文件已保留。请重新添加这个账号。") }
    }
    /// Never replaces a key that may still be needed: without it every saved file would be unreadable.
    private func symmetricKey() throws -> SymmetricKey {
        if let cachedKey, ProcessInfo.processInfo.systemUptime - cachedAt < cacheLifetime { return cachedKey }
        cachedKey = nil
        var raw = try keys.load(interaction: interaction)
        if raw == nil {
            guard !hasSealedFiles else { throw SwitchError("钥匙串中缺少加密密钥，已保存的登录暂时无法解开，文件已保留。") }
            try keys.create(SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }, interaction: interaction)
            raw = try keys.load(interaction: interaction)
        }
        guard let raw, raw.count == 32 else { throw SwitchError("钥匙串中的加密密钥不符合预期，文件已保留。") }
        let key = SymmetricKey(data: raw)
        cachedKey = key; cachedAt = ProcessInfo.processInfo.systemUptime
        cacheExpiry?.cancel()
        let generation = UUID(); cacheGeneration = generation
        let expiry = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.lock.withLock {
                guard self.cacheGeneration == generation else { return }
                self.cachedKey = nil; self.cachedAt = 0; self.cacheExpiry = nil
            }
        }
        cacheExpiry = expiry
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + cacheLifetime, execute: expiry)
        return key
    }
    private var hasSealedFiles: Bool {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.contains { $0.hasSuffix(".vault") }
    }
}

struct Rollback: Codable { let original: Data?; let targetDigest: String; let date: Date }

// Blocking keychain access stays off the main actor. EncryptedFileVault serializes its own I/O.
extension SecretVault {
    func readAsync(_ key: String) async throws -> Data? {
        try Task.checkCancellation()
        let result = try await Task.detached(priority: .userInitiated) { try self.get(key) }.value
        try Task.checkCancellation(); return result
    }
    func writeAsync(_ data: Data, for key: String) async throws {
        try await Task.detached(priority: .userInitiated) { try self.put(data, for: key) }.value
    }
    func unlockAsync(_ keys: [String]) async throws {
        guard let vault = self as? EncryptedFileVault else { return }
        try await Task.detached(priority: .userInitiated) { try vault.unlock(keys) }.value
    }
}
