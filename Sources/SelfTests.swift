import Foundation
import Security
import Darwin

final class MemoryVault: SecretVault {
    var values: [String: Data] = [:]
    var failWrites = false
    func put(_ data: Data, for key: String) throws { if failWrites { throw SwitchError("fixture write error") }; values[key] = data }
    func get(_ key: String) throws -> Data? { values[key] }
    func remove(_ key: String) throws { values.removeValue(forKey: key) }
}
@MainActor enum SelfTests {
    static func fixture(_ subject: String = "test-user-a", account: String = "test-workspace-a", refresh: String = "fixture-refresh-only") throws -> Data {
        let claims: [String: Any] = ["sub": subject, "email": "fixture@example.com", "https://api.openai.com/auth": ["chatgpt_account_id": account, "chatgpt_plan_type": "plus"]]
        let payload = try JSONSerialization.data(withJSONObject: claims).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        return try JSONSerialization.data(withJSONObject: ["auth_mode": "chatgpt", "tokens": ["id_token": "e30." + payload + ".fixture-signature", "access_token": "fixture-access-only", "refresh_token": refresh, "account_id": account]])
    }
    static func run() async -> Bool {
        var passed = 0; var failed = 0
        func check(_ value: Bool, _ name: String) { if value { passed += 1; print("PASS " + name) } else { failed += 1; print("FAIL " + name) } }
        func rejects(_ name: String, _ body: () throws -> Void) { do { try body(); check(false, name) } catch { check(true, name) } }
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("still-switcher-tests-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let a = try fixture(); let b = try fixture("test-user-b", account: "test-workspace-b")
            let ia = try Identity.read(a); let ib = try Identity.read(b)
            check(ia.email == "fixture@example.com" && ia.plan == "plus", "identity display metadata")
            check(ia.key != ib.key, "different users stay distinct")
            check(try Identity.read(fixture(account: "workspace-2")).key != ia.key, "workspaces stay distinct")
            check(try Identity.read(fixture(refresh: "refreshed-fixture")).key == ia.key, "refresh keeps stable identity")
            rejects("API key input rejected") { _ = try Identity.read(Data("{\"OPENAI_API_KEY\":\"test-only\"}".utf8)) }
            rejects("malformed JSON rejected") { _ = try Identity.read(Data("broken".utf8)) }
            rejects("oversized credential rejected") { _ = try Identity.read(Data(repeating: 0, count: 2_000_001)) }
            let auth = root.appendingPathComponent("codex/auth.json")
            try SecureFile.write(a, to: auth)
            check(try SecureFile.read(auth) == a, "credential bytes preserved")
            var s = stat(); _ = stat(auth.path, &s)
            check(s.st_mode & 0o777 == 0o600, "auth file mode 0600")
            let link = root.appendingPathComponent("link.json")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: auth)
            rejects("symlink reads rejected") { _ = try SecureFile.read(link) }
            rejects("symlink writes rejected") { try SecureFile.write(b, to: link) }
            check(try SecureFile.read(auth) == a, "symlink target unchanged")
            let config = root.appendingPathComponent("config.toml")
            try SecureFile.checkFileMode(config); check(true, "default file mode accepted")
            try SecureFile.write(Data("cli_auth_credentials_store = \"file\" # own file\n[profile]\nx=1".utf8), to: config)
            try SecureFile.checkFileMode(config); check(true, "explicit file mode accepted")
            for mode in ["keyring", "auto", "ephemeral"] {
                try SecureFile.write(Data("cli_auth_credentials_store = \"\(mode)\"".utf8), to: config)
                rejects("\(mode) mode preserved and rejected") { try SecureFile.checkFileMode(config) }
            }
            let metadata = root.appendingPathComponent("accounts.json")
            var library = SwitchLibrary(); library.accounts = DemoData.accounts
            try SecureFile.saveLibrary(library, to: metadata)
            check(try SecureFile.loadLibrary(metadata).accounts == library.accounts, "account metadata roundtrip")
            let content = String(data: try SecureFile.read(metadata)!, encoding: .utf8)!
            check(!content.contains("access_token") && !content.contains("refresh_token"), "metadata contains no tokens")
            library.accounts.append(library.accounts[0]); try SecureFile.saveLibrary(library, to: metadata)
            rejects("duplicate metadata rejected") { _ = try SecureFile.loadLibrary(metadata) }
            let broken = Data("{incomplete".utf8); try SecureFile.write(broken, to: metadata)
            rejects("corrupt metadata rejected") { _ = try SecureFile.loadLibrary(metadata) }
            check(try SecureFile.read(metadata) == broken, "corrupt metadata preserved")
            var lock: OperationLock? = try OperationLock(root)
            withExtendedLifetime(lock) { rejects("concurrent transaction locked") { _ = try OperationLock(root) } }
            lock = nil
            _ = try OperationLock(root); check(true, "lock released after transaction")
            let vault = MemoryVault(); let txn = SwitchTransaction(authURL: auth, vault: vault)
            var started = false
            try await txn.replace(with: b) { started = true }
            check(try started && SecureFile.read(auth) == b, "switch writes target and launches")
            let rollback = try JSONDecoder().decode(Rollback.self, from: vault.values["rollback"]!)
            check(rollback.original == a && rollback.targetDigest == SwitchTransaction.digest(b), "rollback persisted before switch")
            try SecureFile.write(a, to: auth)
            do { try await txn.replace(with: b) { throw SwitchError("fixture launch failure") }; check(false, "launch failure rolls back") }
            catch { check(try SecureFile.read(auth) == a, "launch failure rolls back") }
            vault.failWrites = true
            do { try await txn.replace(with: b) {}; check(false, "backup failure blocks switch") }
            catch { check(try SecureFile.read(auth) == a, "backup failure blocks switch") }
            vault.failWrites = false
            do { try await txn.replace(with: Data("invalid".utf8)) {}; check(false, "invalid target leaves current") }
            catch { check(try SecureFile.read(auth) == a, "invalid target leaves current") }
            let external = try fixture("external-user", account: "external-workspace")
            do { try await txn.replace(with: b) { try SecureFile.write(external, to: auth); throw SwitchError("fixture conflict") }; check(false, "foreign update preserved") }
            catch { check(try SecureFile.read(auth) == external, "foreign update preserved") }
            try FileManager.default.removeItem(at: auth)
            do { try await txn.replace(with: b) { throw SwitchError("fixture launch failure") }; check(false, "absent original restored") }
            catch { check(try SecureFile.read(auth) == nil, "absent original restored") }
            check(LoginBroker.validLoginHost("auth.openai.com"), "official login host accepted")
            check(LoginBroker.validLoginHost("auth.chatgpt.com"), "ChatGPT login host accepted")
            check(!LoginBroker.validLoginHost("openai.com.attacker.example"), "suffix impersonation rejected")
            check(!LoginBroker.validLoginHost("evilopenai.com"), "prefix impersonation rejected")
            let modelPaths = AppPaths(root: root.appendingPathComponent("model"), codexHome: root.appendingPathComponent("model-codex"))
            let modelVault = MemoryVault()
            try SecureFile.write(a, to: modelPaths.auth)
            let model = SwitcherModel(paths: modelPaths, vault: modelVault)
            model.saveCurrent()
            check(model.library.accounts.count == 1 && model.errorText == nil, "save current fixture account")
            let saved = model.library.accounts[0]
            model.saveCurrent()
            check(model.library.accounts.count == 1 && model.library.accounts[0].id == saved.id, "saving twice deduplicates account")
            let refreshed = try fixture(refresh: "updated-test-refresh")
            try SecureFile.write(refreshed, to: modelPaths.auth); model.saveCurrent()
            check(try modelVault.get(saved.id.uuidString) == refreshed, "latest refresh token replaces saved fixture")
            model.rename(saved, label: "  Work  ")
            check(model.library.accounts[0].label == "Work", "account note trims whitespace")
            model.setAppearance("dark")
            check(try SecureFile.loadLibrary(modelPaths.metadata).appearance == "dark", "appearance persists")
            let reopened = SwitcherModel(paths: modelPaths, vault: modelVault)
            check(reopened.library.accounts.count == 1 && reopened.active?.label == "Work", "reopening restores list and current indicator")
            modelVault.failWrites = true; model.errorText = nil; model.saveCurrent()
            check(model.errorText != nil && !model.busy, "Keychain save failure leaves UI usable")
            check(try SecureFile.read(modelPaths.auth) == refreshed, "save failure preserves live fixture")
            modelVault.failWrites = false
            try SecureFile.write(Data("broken".utf8), to: modelPaths.metadata)
            let corruptModel = SwitcherModel(paths: modelPaths, vault: modelVault)
            check(!corruptModel.libraryReady, "corrupt list blocks overwrite")
            corruptModel.saveCurrent()
            check(try SecureFile.read(modelPaths.metadata) == Data("broken".utf8), "blocked save preserves corrupt list for repair")
            if CommandLine.arguments.contains("--keychain-test") {
                let service = "app.local.still.codex-switcher.tests." + UUID().uuidString
                let real = KeychainVault(service: service)
                defer { try? real.remove("fixture") }
                try real.put(a, for: "fixture"); check(try real.get("fixture") == a, "isolated Keychain roundtrip")
                try real.put(b, for: "fixture"); check(try real.get("fixture") == b, "isolated Keychain update")
                try real.remove("fixture"); check(try real.get("fixture") == nil, "isolated Keychain cleanup")
            }
        } catch { failed += 1; print("FAIL unexpected fixture error: " + error.localizedDescription) }
        print("RESULT \(passed) passed, \(failed) failed. Fixtures only; no live Codex session touched.")
        return failed == 0
    }
}
