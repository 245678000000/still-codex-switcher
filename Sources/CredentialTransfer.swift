import Foundation
import CryptoKit
import CommonCrypto
import UniformTypeIdentifiers

/// One login carried in an export file. `auth` holds the exact auth.json bytes Codex wrote.
struct TransferAccount: Equatable {
    var label: String
    var email: String
    var plan: String
    var auth: Data
}

/// Password-encrypted account export shared by the Mac and Windows apps.
/// PBKDF2-HMAC-SHA256 (NFC-normalised UTF-8 password) → AES-256-GCM. See docs/credential-transfer.md.
enum CredentialTransfer {
    static let format = "still-codex-accounts"
    static let fileExtension = "stillcodex"
    static let iterations = 600_000
    static let minimumPassword = 8
    static let maximumAccounts = 200
    static var fileType: UTType { UTType(filenameExtension: fileExtension, conformingTo: .json) ?? .json }
    private static let associatedData = Data("still-codex-accounts/v1".utf8)

    private struct Envelope: Codable {
        struct KDF: Codable { var name: String; var iterations: Int; var salt: String }
        var format: String
        var version: Int
        var kdf: KDF
        var cipher: String
        var nonce: String
        var ciphertext: String
        var tag: String
        var createdAt: Date
    }
    private struct Payload: Codable {
        struct Item: Codable { var label: String; var email: String; var plan: String; var auth: Data }
        var app: String
        var exportedAt: Date
        var accounts: [Item]
    }
    enum ImportAction: Equatable { case add, update, same, olderThanSaved }
    struct ImportItem {
        let account: TransferAccount
        let identity: Identity
        let action: ImportAction
        let existing: SavedAccount?
    }

    private static func encoder() -> JSONEncoder {
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]; e.dateEncodingStrategy = .iso8601; return e
    }
    private static func decoder() -> JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }
    private static func randomBytes(_ count: Int) -> Data {
        SymmetricKey(size: SymmetricKeySize(bitCount: count * 8)).withUnsafeBytes { Data($0) }
    }
    static func defaultLabel(_ email: String) -> String {
        email.contains("@") ? String(email.split(separator: "@")[0]) : "我的账号"
    }
    static func deriveKey(_ password: String, salt: Data, iterations: Int) throws -> SymmetricKey {
        let secret = Array(password.precomposedStringWithCanonicalMapping.utf8).map { CChar(bitPattern: $0) }
        let saltBytes = [UInt8](salt)
        let keyLength = 32
        var derived = [UInt8](repeating: 0, count: keyLength)
        let status = CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), secret, secret.count, saltBytes, saltBytes.count,
                                          CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), UInt32(iterations), &derived, keyLength)
        guard Int(status) == Int(kCCSuccess) else { throw SwitchError("密钥派生失败，请重试。") }
        return SymmetricKey(data: derived)
    }

    static func seal(_ accounts: [TransferAccount], password: String, app: String, now: Date = Date()) throws -> Data {
        guard password.count >= minimumPassword else { throw SwitchError("导出密码至少 \(minimumPassword) 位。") }
        guard !accounts.isEmpty else { throw SwitchError("请至少选择一个账号。") }
        guard accounts.count <= maximumAccounts else { throw SwitchError("一次最多导出 \(maximumAccounts) 个账号。") }
        for item in accounts { _ = try Identity.read(item.auth) }
        let payload = Payload(app: app, exportedAt: now, accounts: accounts.map { Payload.Item(label: $0.label, email: $0.email, plan: $0.plan, auth: $0.auth) })
        let plain = try encoder().encode(payload)
        let salt = randomBytes(16)
        let key = try deriveKey(password, salt: salt, iterations: iterations)
        let nonce = AES.GCM.Nonce()
        let box = try AES.GCM.seal(plain, using: key, nonce: nonce, authenticating: associatedData)
        let envelope = Envelope(format: format, version: 1,
                                kdf: Envelope.KDF(name: "PBKDF2-HMAC-SHA256", iterations: iterations, salt: salt.base64EncodedString()),
                                cipher: "AES-256-GCM", nonce: nonce.withUnsafeBytes { Data($0) }.base64EncodedString(),
                                ciphertext: box.ciphertext.base64EncodedString(), tag: box.tag.base64EncodedString(), createdAt: now)
        return try encoder().encode(envelope)
    }

    static func isEnvelope(_ data: Data) -> Bool {
        guard data.count < 4_000_000, let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return false }
        return object["format"] as? String == format
    }

    static func open(_ data: Data, password: String) throws -> [TransferAccount] {
        guard let envelope = try? decoder().decode(Envelope.self, from: data), envelope.format == format else {
            throw SwitchError("无法识别这个导出文件，或文件已损坏。")
        }
        guard envelope.version == 1 else { throw SwitchError("这个导出文件来自更新版本的栖言，请先更新后再导入。") }
        guard envelope.kdf.name == "PBKDF2-HMAC-SHA256", envelope.cipher == "AES-256-GCM",
              (100_000...10_000_000).contains(envelope.kdf.iterations),
              let salt = Data(base64Encoded: envelope.kdf.salt), salt.count >= 16,
              let nonce = Data(base64Encoded: envelope.nonce), nonce.count == 12,
              let ciphertext = Data(base64Encoded: envelope.ciphertext),
              let tag = Data(base64Encoded: envelope.tag), tag.count == 16 else {
            throw SwitchError("导出文件参数异常，已停止导入。")
        }
        let key = try deriveKey(password, salt: salt, iterations: envelope.kdf.iterations)
        let plain: Data
        do {
            let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: nonce), ciphertext: ciphertext, tag: tag)
            plain = try AES.GCM.open(box, using: key, authenticating: associatedData)
        } catch { throw SwitchError("密码不正确，或文件内容已被修改。") }
        guard let payload = try? decoder().decode(Payload.self, from: plain) else { throw SwitchError("导出内容格式异常。") }
        guard !payload.accounts.isEmpty, payload.accounts.count <= maximumAccounts else { throw SwitchError("导出文件中没有可导入的账号。") }
        return try payload.accounts.map { (item) -> TransferAccount in
            let identity = try Identity.read(item.auth)
            let label = String(item.label.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
            return TransferAccount(label: label.isEmpty ? defaultLabel(identity.email) : label, email: identity.email, plan: identity.plan, auth: item.auth)
        }
    }

    /// A plain Codex auth.json (for example copied from another computer's ~/.codex).
    static func fromAuthFile(_ data: Data) throws -> TransferAccount {
        let identity = try Identity.read(data)
        return TransferAccount(label: defaultLabel(identity.email), email: identity.email, plan: identity.plan, auth: data)
    }

    /// Classifies each incoming login against the saved list. Duplicates inside one file keep the newest copy.
    static func plan(_ incoming: [TransferAccount], library: SwitchLibrary, saved: (SavedAccount) throws -> Data?) throws -> [ImportItem] {
        var best: [String: TransferAccount] = [:]
        var identities: [String: Identity] = [:]
        var order: [String] = []
        for item in incoming {
            let identity = try Identity.read(item.auth)
            if let current = best[identity.key] {
                if CredentialStamp.read(current.auth)?.isOlder(than: CredentialStamp.read(item.auth)) == true { best[identity.key] = item }
            } else {
                best[identity.key] = item; identities[identity.key] = identity; order.append(identity.key)
            }
        }
        var result: [ImportItem] = []
        for key in order {
            guard let item = best[key], let identity = identities[key] else { continue }
            guard let existing = library.accounts.first(where: { $0.identityKey == key }) else {
                result.append(ImportItem(account: item, identity: identity, action: .add, existing: nil)); continue
            }
            let current = try saved(existing)
            let action: ImportAction
            if current == item.auth { action = .same }
            else if let current, CredentialStamp.read(item.auth)?.isOlder(than: CredentialStamp.read(current)) == true { action = .olderThanSaved }
            else { action = .update }
            result.append(ImportItem(account: item, identity: identity, action: action, existing: existing))
        }
        return result
    }
}
