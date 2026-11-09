import Foundation

/// Fixtures for auth state, freshness-aware saving, live sync and encrypted transfer. No network, no live Codex.
@MainActor enum AuthTests {
    static func jwt(_ claims: [String: Any]) throws -> String {
        let payload = try JSONSerialization.data(withJSONObject: claims, options: [.sortedKeys]).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        return "e30." + payload + ".fixture-signature"
    }
    /// A fixture login whose access token carries iat/exp like a real ChatGPT login.
    static func login(_ subject: String = "auth-user", account: String = "auth-workspace", issued: Date, expires: Date, refresh: String, lastRefresh: String? = nil) throws -> Data {
        let idClaims: [String: Any] = ["sub": subject, "email": "auth@example.com", "https://api.openai.com/auth": ["chatgpt_account_id": account, "chatgpt_plan_type": "plus"]]
        let access = try jwt(["iat": Int(issued.timeIntervalSince1970), "exp": Int(expires.timeIntervalSince1970), "fixture": refresh])
        var object: [String: Any] = ["OPENAI_API_KEY": NSNull(), "tokens": ["id_token": try jwt(idClaims), "access_token": access, "refresh_token": "fixture-refresh-" + refresh, "account_id": account]]
        if let lastRefresh { object["last_refresh"] = lastRefresh }
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
    static func run(_ check: (Bool, String) -> Void, root: URL) throws {
        func rejects(_ name: String, _ body: () throws -> Void) { do { try body(); check(false, name) } catch { check(true, name) } }
        let now = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
        let day: TimeInterval = 86_400

        // Stamps: local token times only, never token text.
        let base = try login(issued: now.addingTimeInterval(-3600), expires: now.addingTimeInterval(day), refresh: "base")
        let stamp = CredentialStamp.read(base)
        check(stamp?.issuedAt == now.addingTimeInterval(-3600) && stamp?.expiresAt == now.addingTimeInterval(day) && stamp?.fingerprint.count == 16, "stamp reads access token times with a short fingerprint")
        let encodedStamp = String(decoding: try JSONEncoder().encode(stamp), as: UTF8.self)
        check(!encodedStamp.contains("fixture-refresh") && !encodedStamp.contains("e30."), "stamp contains no token text")
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime]
        let refreshedAt = now.addingTimeInterval(-60)
        let nanos = formatter.string(from: refreshedAt).replacingOccurrences(of: "Z", with: ".250000000Z")
        let withRefresh = try login(issued: now.addingTimeInterval(-7200), expires: now.addingTimeInterval(day), refresh: "nanos", lastRefresh: nanos)
        check(abs((CredentialStamp.read(withRefresh)?.issuedAt ?? .distantPast).timeIntervalSince(refreshedAt.addingTimeInterval(0.25))) < 0.001, "last_refresh with nanoseconds counts as issue time")
        check(CredentialStamp.parseDate("2026-11-04T10:00:00+08:00") == formatter.date(from: "2026-11-04T02:00:00Z"), "RFC 3339 offset parsed")
        let older = CredentialStamp(fingerprint: "a", issuedAt: now.addingTimeInterval(-100), expiresAt: nil)
        let newer = CredentialStamp(fingerprint: "b", issuedAt: now, expiresAt: nil)
        check(older.isOlder(than: newer) && !newer.isOlder(than: older), "freshness comparison")
        check(!CredentialStamp(fingerprint: "c", issuedAt: nil, expiresAt: nil).isOlder(than: newer) && !older.isOlder(than: nil), "unknown times never block an update")

        // Health states.
        let live = CredentialStamp(fingerprint: "f", issuedAt: now.addingTimeInterval(-day), expiresAt: now.addingTimeInterval(day))
        let gone = CredentialStamp(fingerprint: "f", issuedAt: now.addingTimeInterval(-day * 3), expiresAt: now.addingTimeInterval(-60))
        func health(_ s: CredentialStamp?, _ v: AuthVerdict?) -> AuthHealth { AuthHealth.evaluate(stamp: s, verdict: v, now: now) }
        check(health(live, nil) == .unverified(expiresAt: live.expiresAt), "unchecked login is unverified")
        check(health(nil, nil) == .unverified(expiresAt: nil), "legacy account without stamp is unverified")
        check(health(live, AuthVerdict(kind: .accepted, fingerprint: "f", at: now)) == .valid(expiresAt: live.expiresAt), "accepted login is valid")
        check(health(live, AuthVerdict(kind: .rejected, fingerprint: "f", at: now)) == .invalid(since: now), "rejected unexpired login is invalid")
        check(health(gone, AuthVerdict(kind: .rejected, fingerprint: "f", at: now)) == .expired(at: gone.expiresAt!), "401 after expiry is only expired")
        check(health(gone, AuthVerdict(kind: .accepted, fingerprint: "f", at: now.addingTimeInterval(-day))) == .expired(at: gone.expiresAt!), "accepted then expired shows expired")
        check(health(live, AuthVerdict(kind: .rejected, fingerprint: "other", at: now)) == .unverified(expiresAt: live.expiresAt), "verdict for another copy is ignored")
        check(AuthHealth.invalid(since: now).tone == .danger && AuthHealth.valid(expiresAt: nil).tone == .good, "invalid and valid read as different tones")

        // Protocol: a 401 refresh request is a typed rejection.
        var quota = QuotaProtocol(credentials: try QuotaCredentials.read(base, expectedKey: try Identity.read(base).key))
        do { _ = try quota.receive(["method": "account/chatgptAuthTokens/refresh", "id": 7, "params": ["reason": "unauthorized"]]); check(false, "401 refresh request reported as rejected login") }
        catch { check(error is AuthRejectedError, "401 refresh request reported as rejected login") }

        // Model: re-login while Codex still holds the old file.
        let paths = AppPaths(root: root.appendingPathComponent("model"), codexHome: root.appendingPathComponent("codex"))
        let vault = MemoryVault()
        let old = try login(issued: now.addingTimeInterval(-day * 2), expires: now.addingTimeInterval(day * 5), refresh: "old")
        try SecureFile.write(old, to: paths.auth)
        let model = SwitcherModel(paths: paths, vault: vault)
        model.saveCurrent()
        guard let first = model.library.accounts.first else { check(false, "auth fixture account saved"); return }
        let id = first.id
        check(first.stamp == CredentialStamp.read(old) && first.credentialSource == "codex", "saving records the stamp and source")
        let fresh = try login(issued: now, expires: now.addingTimeInterval(day * 10), refresh: "fresh")
        check(try model.store(fresh, source: .login) == .updated(id) && vault.values[id.uuidString] == fresh, "re-login replaces the saved copy")
        model.saveCurrent()
        check(vault.values[id.uuidString] == fresh && model.staleLive.contains(id), "stale auth.json never overwrites a newer login")
        check(model.syncLiveCredential() == .keptNewer(id) && vault.values[id.uuidString] == fresh, "live sync keeps the newer saved login")
        check(try model.freshestCredential(model.library.accounts[0]) == fresh, "queries use the newer saved login")
        check(try SecureFile.read(paths.auth) == old, "saving and syncing never write Codex's auth.json")

        // Codex renews or re-logs in on its own: picked up immediately.
        let renewed = try login(issued: now.addingTimeInterval(60), expires: now.addingTimeInterval(day * 11), refresh: "renewed")
        try SecureFile.write(renewed, to: paths.auth)
        check(model.syncLiveCredential() == .updated(id) && vault.values[id.uuidString] == renewed && !model.staleLive.contains(id), "live sync picks up a renewed Codex login")
        check(model.syncLiveCredential() == .unchanged(id), "live sync is idempotent")
        check(model.library.accounts[0].stamp == CredentialStamp.read(renewed), "live sync updates the stamp")
        let stranger = try login("stranger", account: "stranger-workspace", issued: now, expires: now.addingTimeInterval(day), refresh: "stranger")
        try SecureFile.write(stranger, to: paths.auth)
        check(model.syncLiveCredential() == nil && model.library.accounts.count == 1, "live sync never adds unsaved accounts")
        try SecureFile.write(renewed, to: paths.auth)

        // Verdicts follow the exact copy.
        model.recordVerdict(model.library.accounts[0], stamp: CredentialStamp.read(renewed), kind: .rejected)
        check(model.health(model.library.accounts[0]).isInvalid && model.invalidAccounts.count == 1, "rejected login shows as invalid")
        check(try SecureFile.loadLibrary(paths.metadata).accounts[0].verdict?.kind == .rejected, "verdict persists across restarts")
        model.recordVerdict(model.library.accounts[0], stamp: CredentialStamp.read(old), kind: .accepted)
        check(model.health(model.library.accounts[0]).isInvalid, "verdict for an older copy is ignored")
        let relogin = try login(issued: now.addingTimeInterval(120), expires: now.addingTimeInterval(day * 12), refresh: "relogin")
        try model.store(relogin, source: .login)
        check(model.health(model.library.accounts[0]) == .unverified(expiresAt: now.addingTimeInterval(day * 12)) && model.quotas[id]?.error == nil, "new login clears the old rejection until verified")
        model.recordVerdict(model.library.accounts[0], stamp: CredentialStamp.read(relogin), kind: .accepted)
        check(model.health(model.library.accounts[0]) == .valid(expiresAt: now.addingTimeInterval(day * 12)) && model.invalidAccounts.isEmpty, "verified new login is valid")

        // Encrypted transfer.
        let items = [TransferAccount(label: "工作", email: "auth@example.com", plan: "plus", auth: relogin)]
        let sealed = try CredentialTransfer.seal(items, password: "correct horse", app: "fixture")
        let envelope = String(decoding: sealed, as: UTF8.self)
        check(CredentialTransfer.isEnvelope(sealed) && !envelope.contains("fixture-refresh") && !envelope.contains("auth@example.com") && !envelope.contains("e30."), "export file hides tokens and emails")
        check(try CredentialTransfer.open(sealed, password: "correct horse") == items, "export roundtrip restores exact login bytes")
        rejects("wrong export password rejected") { _ = try CredentialTransfer.open(sealed, password: "wrong horse") }
        if var object = try JSONSerialization.jsonObject(with: sealed) as? [String: Any], let cipher = object["ciphertext"] as? String {
            let flipped: String = (cipher.first == "A" ? "B" : "A") + String(cipher.dropFirst())
            object["ciphertext"] = flipped
            let forged = try JSONSerialization.data(withJSONObject: object)
            rejects("tampered export rejected") { _ = try CredentialTransfer.open(forged, password: "correct horse") }
        } else { check(false, "tampered export rejected") }
        rejects("short export password rejected") { _ = try CredentialTransfer.seal(items, password: "short", app: "fixture") }
        rejects("API key file import rejected") { _ = try CredentialTransfer.fromAuthFile(Data("{\"OPENAI_API_KEY\":\"fixture\"}".utf8)) }
        check(try CredentialTransfer.fromAuthFile(relogin).auth == relogin, "plain auth.json import accepted")

        // Import planning and apply.
        func actions(_ list: [Data]) throws -> [CredentialTransfer.ImportAction] {
            try CredentialTransfer.plan(list.map { TransferAccount(label: "x", email: "", plan: "", auth: $0) }, library: model.library) { try vault.get($0.id.uuidString) }.map(\.action)
        }
        let friend = try login("friend", account: "friend-workspace", issued: now, expires: now.addingTimeInterval(day), refresh: "friend")
        let newest = try login(issued: now.addingTimeInterval(300), expires: now.addingTimeInterval(day * 12), refresh: "newest")
        check(try actions([old]) == [.olderThanSaved], "import skips an older copy of a saved account")
        check(try actions([relogin]) == [.same], "import recognises the identical copy")
        check(try actions([newest]) == [.update], "import updates with a newer copy")
        check(try actions([friend]) == [.add], "import adds an unknown account")
        check(try actions([old, newest, old]) == [.update], "duplicates in one file keep the newest copy")
        model.applyImport([TransferAccount(label: "朋友", email: "", plan: "", auth: friend), TransferAccount(label: "旧", email: "", plan: "", auth: old)], source: "fixture", confirmFirst: false)
        check(model.library.accounts.count == 2 && model.library.accounts.contains { $0.label == "朋友" && $0.credentialSource == "imported" }, "import adds new accounts with their label")
        check(vault.values[id.uuidString] == relogin && model.errorText == nil && !model.busy, "import never downgrades a saved login")
        check(try SecureFile.read(paths.auth) == renewed, "import never writes Codex's auth.json")
    }
}
