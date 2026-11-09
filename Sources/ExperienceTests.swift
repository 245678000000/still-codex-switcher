import Foundation
import Security

@MainActor enum ExperienceTests {
    final class LockedKeys: VaultKeyStore {
        var key = Data(repeating: 3, count: 32)
        var locked = false
        var interactions: [VaultInteraction] = []
        func load() throws -> Data? { try load(interaction: .silent) }
        func load(interaction: VaultInteraction) throws -> Data? {
            interactions.append(interaction)
            if locked && interaction == .silent { throw VaultLockedError() }
            return key
        }
        func create(_ data: Data) throws { key = data }
    }
    final class ObservedVault: SecretVault {
        var values: [String: Data] = [:]
        var writeOnMain = false
        func get(_ key: String) throws -> Data? { values[key] }
        func put(_ data: Data, for key: String) throws { writeOnMain = Thread.isMainThread; values[key] = data }
        func remove(_ key: String) throws { values.removeValue(forKey: key) }
    }
    static func cli(_ root: URL, name: String, response: String) throws -> URL {
        try QuotaBroker.privateDirectory(root)
        let url = root.appendingPathComponent(name)
        let script = """
        #!/bin/sh
        test -d "$CODEX_HOME" || exit 4
        test ! -e "$CODEX_HOME/auth.json" || exit 5
        IFS= read -r line
        printf '%s\\n' '{"id":1,"result":{}}'
        IFS= read -r line
        IFS= read -r line
        printf '%s\\n' '{"id":2,"result":{"type":"chatgptAuthTokens"}}'
        IFS= read -r line
        case "$line" in *rateLimits*) ;; *) exit 6 ;; esac
        printf '%s\\n' '\(response)'
        """
        try Data(script.utf8).write(to: url); chmod(url.path, 0o700)
        return url
    }
    static func run(_ check: (Bool, String) -> Void, root: URL) async throws {
        let keys = VaultTests.MemoryKeys()
        let vault = EncryptedFileVault(directory: root, keys: keys, legacy: [])
        let data = Data("synthetic credential".utf8)
        try vault.put(data, for: "fixture")
        let loads = keys.loads
        vault.clearCachedSecrets()
        check(try vault.get("fixture") == data && keys.loads > loads, "lock or quit discards cached vault key before next read")
        let paths = AppPaths(root: root.appendingPathComponent("model"), codexHome: root.appendingPathComponent("home"))
        let model = SwitcherModel(paths: paths, vault: MemoryVault())
        let login = try AuthTests.login(issued: Date(), expires: Date().addingTimeInterval(3600), refresh: "new-login")
        let id = try model.store(login, source: .login).id
        model.verifySoon(id)
        check(model.health(model.library.accounts[0]).title == "验证中", "relogin immediately shows verifying instead of old valid badge")
        let lockedKeys = LockedKeys()
        let lockedVault = EncryptedFileVault(directory: root.appendingPathComponent("locked"), keys: lockedKeys, legacy: [])
        try lockedVault.put(data, for: "account")
        lockedVault.clearCachedSecrets(); lockedKeys.locked = true
        do { _ = try lockedVault.get("account"); check(false, "locked background read reports unlock-needed") }
        catch { check(error is VaultLockedError, "locked background read reports unlock-needed") }
        check(lockedKeys.interactions.allSatisfy { $0 == .silent }, "background path never requests interactive authentication")
        try await lockedVault.unlockAsync(["account"])
        check(try lockedVault.get("account") == data, "explicit unlock resumes preserved encrypted credential")
        check(lockedKeys.interactions.filter { $0 == .userInitiated }.count == 1, "unlock authorizes one master key load")
        let before = lockedKeys.interactions.count
        _ = try lockedVault.get("account"); _ = try lockedVault.get("account")
        check(lockedKeys.interactions.count == before, "repeat reads reuse authorized short-lived memory key")
        let silentQuery = NativeKeychain.query(service: "fixture", account: "fixture")
        check(silentQuery[kSecUseAuthenticationUI as String] as? String == kSecUseAuthenticationUIFail as String, "native legacy keychain policy prohibits background prompt")
        let success = try cli(root, name: "success-cli", response: #"{"id":3,"result":{"rateLimits":{"primary":{"usedPercent":12,"windowDurationMins":300}}}}"#)
        let rejected = try cli(root, name: "rejected-cli", response: #"{"id":9,"method":"account/chatgptAuthTokens/refresh","params":{"reason":"unauthorized"}}"#)
        let offline = try cli(root, name: "offline-cli", response: #"{"id":3,"error":{"code":-1,"message":"fixture-offline"}}"#)
        model.verifySoon(id, cliOverride: success)
        await model.waitForQuotaRefresh()
        check(model.health(model.library.accounts[0]).title == "认证有效" && model.message.contains("验证完成"), "new login automatically becomes valid after service acknowledgement")
        check(model.quotas[id]?.snapshot?.fiveHours?.remaining == 88, "login verification refreshes quota without sending a model turn")
        model.verifySoon(id, cliOverride: rejected); await model.waitForQuotaRefresh()
        check(model.health(model.library.accounts[0]).title == "登录已失效" && model.invalidAccounts.count == 1, "service rejection produces prominent invalid login state")
        model.verifySoon(id, cliOverride: offline); await model.waitForQuotaRefresh()
        check(model.health(model.library.accounts[0]).isInvalid, "transient failure does not erase an already confirmed rejection")
        let fresh = try AuthTests.login(issued: Date(), expires: Date().addingTimeInterval(7200), refresh: "relogin-new")
        try model.store(fresh, source: .login)
        model.verifySoon(id, cliOverride: offline); await model.waitForQuotaRefresh()
        check(model.health(model.library.accounts[0]) == .unavailable && model.invalidAccounts.isEmpty, "network or protocol error is not labelled invalid login")
        model.verifySoon(id, cliOverride: success); await model.waitForQuotaRefresh()
        check(model.health(model.library.accounts[0]).title == "认证有效" && model.quotas[id]?.error == nil, "retry clears transient errors immediately")
        // The header reflects the actual live file, not merely a newer saved login.
        try SecureFile.write(login, to: paths.auth); model.refresh(); model.staleLive.insert(id)
        check(model.currentHealth.title != "认证有效" && model.health(model.library.accounts[0]).title == "认证有效", "saved valid login does not mislabel the old running login")
        // Priority verification cancels only our isolated slow child and does not run the next sweep account.
        let slow = root.appendingPathComponent("slow-cli")
        let marker = root.appendingPathComponent("started")
        try Data("#!/bin/sh\nprintf x > '\(marker.path)'\nexec /bin/sleep 5\n".utf8).write(to: slow); chmod(slow.path, 0o700)
        let second = try AuthTests.login("second", account: "second", issued: Date(), expires: Date().addingTimeInterval(7200), refresh: "second")
        let secondID = try model.store(second, source: .login).id
        model.refreshQuotas(forceRefresh: true, cliOverride: slow)
        for _ in 0..<200 {
            if FileManager.default.fileExists(atPath: marker.path) { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        check(FileManager.default.fileExists(atPath: marker.path), "slow background fixture starts before re-login")
        let newer = try AuthTests.login(issued: Date(), expires: Date().addingTimeInterval(9000), refresh: "priority-login")
        try model.store(newer, source: .login)
        let began = Date(); model.verifySoon(id, cliOverride: success); await model.waitForQuotaRefresh()
        check(Date().timeIntervalSince(began) < 3 && model.health(model.library.accounts[0]).title == "认证有效", "relogin verification preempts background sweep promptly")
        check(model.quotas[secondID]?.attemptedAt == nil, "cancelled sweep does not query the next account")
        check(model.quotas[id]?.error == nil && model.library.accounts[0].verdict?.fingerprint == CredentialStamp.read(newer)?.fingerprint, "old request completion cannot overwrite newly verified login")
        check(try SecureFile.read(paths.auth) == login, "all login checks leave the running Codex credential unchanged")
        let transactionVault = ObservedVault()
        let transactionURL = root.appendingPathComponent("transaction/auth.json")
        try SecureFile.write(login, to: transactionURL)
        let transaction = SwitchTransaction(authURL: transactionURL, vault: transactionVault)
        do { try await transaction.replace(with: newer) { throw SwitchError("fixture launch failure") }; check(false, "failed launch rolls back") }
        catch { check(try SecureFile.read(transactionURL) == login, "failed launch rolls back exact original login") }
        check(!transactionVault.writeOnMain, "durable switch backup keeps blocking vault work off main thread")
        check(transactionVault.values["rollback"] != nil, "switch failure retains durable rollback backup")

        let shortKeys = LockedKeys()
        let shortVault = EncryptedFileVault(directory: root.appendingPathComponent("short-cache"), keys: shortKeys, legacy: [], cacheLifetime: 0.02)
        try shortVault.put(data, for: "fixture"); shortKeys.locked = true
        try await Task.sleep(for: .milliseconds(50))
        do { _ = try shortVault.get("fixture"); check(false, "short cache expires even while idle") }
        catch { check(error is VaultLockedError, "short cache expires even while idle") }
        let unlockPaths = AppPaths(root: root.appendingPathComponent("unlock-model"), codexHome: root.appendingPathComponent("unused-home"))
        let unlockKeys = LockedKeys()
        let unlockVault = EncryptedFileVault(directory: unlockPaths.root.appendingPathComponent("vault"), keys: unlockKeys, legacy: [])
        let unlockModel = SwitcherModel(paths: unlockPaths, vault: unlockVault)
        let unlockID = try unlockModel.store(login, source: .login).id
        unlockKeys.locked = true; unlockVault.clearCachedSecrets()
        unlockModel.refreshQuotas(forceRefresh: true, cliOverride: success); await unlockModel.waitForQuotaRefresh()
        check(unlockModel.health(unlockModel.library.accounts[0]) == .locked && unlockKeys.interactions.allSatisfy { $0 == .silent }, "background model refresh reports locked without any authorization UI")
        unlockModel.unlockLogin(unlockModel.library.accounts[0], cliOverride: success)
        for _ in 0..<400 { if !unlockModel.busy { break }; try await Task.sleep(for: .milliseconds(5)) }
        await unlockModel.waitForQuotaRefresh()
        check(unlockModel.health(unlockModel.library.accounts[0]).title == "认证有效" && !unlockModel.busy && unlockModel.quotas[unlockID]?.error == nil, "explicit model unlock retries verification and becomes valid")
        check(try unlockVault.get(unlockID.uuidString) == login, "unlock retry preserves exact saved login")


    }
}
