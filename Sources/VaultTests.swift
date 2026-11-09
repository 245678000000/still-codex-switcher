import Foundation

/// Fixtures for the encrypted credential files and for moving older Keychain items. No real Keychain.
enum VaultTests {
    final class MemoryKeys: VaultKeyStore {
        var value: Data?; var loads = 0; var creates = 0; var failLoad = false
        func load() throws -> Data? { loads += 1; if failLoad { throw SwitchError("fixture key denied") }; return value }
        func create(_ key: Data) throws { creates += 1; value = key }
    }
    final class MemoryLegacy: LegacyCredentialStore {
        var values: [String: Data] = [:]; var reads = 0; var failRead = false
        func read(_ key: String) throws -> Data? { reads += 1; if failRead { throw SwitchError("fixture denied") }; return values[key] }
        func delete(_ key: String) throws { values.removeValue(forKey: key) }
    }
    static func run(_ check: (Bool, String) -> Void, root: URL) throws {
        let fm = FileManager.default
        let secret = Data("{\"tokens\":\"虚构的登录\"}\n".utf8) + Data([0, 255])
        let other = Data("fixture-other".utf8)
        func rejects(_ body: () throws -> Void) -> Bool { do { try body(); return false } catch { return true } }
        func mode(_ url: URL) -> Int { ((try? fm.attributesOfItem(atPath: url.path))?[.posixPermissions] as? Int) ?? -1 }

        let dir = root.appendingPathComponent("basic"); let keys = MemoryKeys()
        let vault = EncryptedFileVault(directory: dir, keys: keys, legacy: [])
        check(try vault.get("a") == nil, "vault missing credential is nil")
        check(keys.creates == 0, "vault read creates no key")
        try vault.put(secret, for: "a"); check(try vault.get("a") == secret, "vault keeps exact bytes")
        try vault.put(other, for: "a"); check(try vault.get("a") == other, "vault replaces value")
        check(keys.creates == 1 && keys.loads <= 2, "vault creates and loads key once")
        let file = dir.appendingPathComponent("a.vault")
        check(mode(file) == 0o600, "vault file mode 0600")
        check(mode(dir) == 0o700, "vault directory mode 0700")
        check(try Data(contentsOf: file).range(of: other) == nil, "vault file holds no plaintext")
        let names = try fm.contentsOfDirectory(atPath: dir.path)
        check(names == ["a.vault"], "vault leaves no temporary files")
        check(try EncryptedFileVault(directory: dir, keys: keys, legacy: []).get("a") == other, "new instance reads with same key")
        check(keys.creates == 1, "new instance keeps existing key")
        check(rejects { try vault.put(secret, for: "../escape") }, "vault rejects path in credential name")
        check(!fm.fileExists(atPath: root.appendingPathComponent("escape.vault").path), "rejected name writes nothing")

        try vault.put(secret, for: "b")
        let bFile = dir.appendingPathComponent("b.vault"); let good = try Data(contentsOf: bFile)
        var tampered = good; tampered[tampered.count - 1] ^= 1; try tampered.write(to: bFile)
        check(rejects { _ = try vault.get("b") }, "tampered file rejected")
        check(try Data(contentsOf: bFile) == tampered, "tampered file preserved")
        try good.write(to: dir.appendingPathComponent("c.vault"))
        check(rejects { _ = try vault.get("c") }, "another account's file rejected")
        try fm.removeItem(at: dir.appendingPathComponent("c.vault")); try good.write(to: bFile)

        let wrong = MemoryKeys(); wrong.value = Data(repeating: 7, count: 32)
        check(rejects { _ = try EncryptedFileVault(directory: dir, keys: wrong, legacy: []).get("b") }, "wrong key rejected")
        let lost = MemoryKeys()
        check(rejects { _ = try EncryptedFileVault(directory: dir, keys: lost, legacy: []).get("b") }, "missing key with saved files refused")
        check(rejects { try EncryptedFileVault(directory: dir, keys: lost, legacy: []).put(other, for: "d") }, "missing key blocks new saves")
        check(lost.creates == 0 && lost.value == nil, "missing key is never regenerated over saved files")
        let denied = MemoryKeys(); denied.failLoad = true
        check(rejects { _ = try EncryptedFileVault(directory: dir, keys: denied, legacy: []).get("b") }, "denied key read reported")
        check(denied.creates == 0, "denied key read creates nothing")
        check(try vault.get("b") == secret, "saved file survives failed attempts")
        let short = MemoryKeys(); short.value = Data(repeating: 7, count: 16)
        check(rejects { _ = try EncryptedFileVault(directory: root.appendingPathComponent("short"), keys: short, legacy: []).put(other, for: "a") }, "malformed key rejected")

        let shared = MemoryLegacy(), restricted = MemoryLegacy()
        let moved = EncryptedFileVault(directory: root.appendingPathComponent("moved"), keys: MemoryKeys(), legacy: [shared, restricted])
        shared.values["a"] = secret; restricted.values["a"] = other
        check(try moved.get("a") == secret, "newer legacy store wins")
        check(shared.values.isEmpty && restricted.values.isEmpty, "both legacy copies removed after move")
        let reads = shared.reads + restricted.reads
        check(try moved.get("a") == secret && shared.reads + restricted.reads == reads, "moved credential never touches Keychain again")
        restricted.values["b"] = other
        check(try moved.get("b") == other && restricted.values.isEmpty, "older legacy store moved")
        check(try moved.get("unknown") == nil, "unknown credential is nil")

        shared.values["e"] = secret; shared.failRead = true
        check(rejects { _ = try moved.get("e") }, "denied legacy read reported")
        check(shared.values["e"] == secret && !fm.fileExists(atPath: root.appendingPathComponent("moved/e.vault").path), "denied legacy read loses nothing")
        shared.failRead = false

        shared.values["f"] = secret; let before = shared.reads
        try moved.put(other, for: "f")
        check(shared.values["f"] == nil && shared.reads == before, "new value replaces legacy copy without reading it")
        check(try moved.get("f") == other, "new value wins over legacy copy")
        restricted.values["g"] = secret
        try moved.remove("g"); check(restricted.values["g"] == nil, "remove clears unmoved legacy copy")
        try moved.remove("f"); check(try moved.get("f") == nil, "remove deletes file")

        let blockedDir = root.appendingPathComponent("blocked")
        try fm.createDirectory(at: blockedDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o500])
        defer { try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: blockedDir.path) }
        let kept = MemoryLegacy(); kept.values["a"] = secret
        let blocked = EncryptedFileVault(directory: blockedDir, keys: MemoryKeys(), legacy: [kept])
        check(try blocked.get("a") == secret, "failed move still returns credential")
        check(kept.values["a"] == secret, "failed move keeps legacy copy")
        check(rejects { try blocked.put(other, for: "a") }, "failed save reported")
        check(kept.values["a"] == secret, "failed save keeps legacy copy")
    }
}
