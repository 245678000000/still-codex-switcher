import Foundation
import Darwin

@MainActor enum ResetCreditTests {
    static func run(_ check: (Bool, String) -> Void, root: URL) async throws {
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let quota = try QuotaSnapshot.parse(["rateLimitResetCredits": ["availableCount": 3, "credits": [
            ["id": "fixture-card", "resetType": "codexRateLimits", "status": "available", "expiresAt": 1_900_086_400]
        ]]], now: now)
        check(quota.resetCredits?.availableCount == 3, "reset count uses server total, not capped detail row count")
        check(quota.resetCredits?.credits?.first?.expiresAt == now.addingTimeInterval(86400), "reset expiry uses Unix seconds")
        check(quota.resetCredits?.expiryLabel(now: now).contains("已知") == true, "reset partial expiry details labelled")
        let state = QuotaState(snapshot: quota)
        check(try ResetAttempt.prepare(existing: nil, state: state, confirmed: false, now: now) == nil, "reset cancel creates no attempt")
        let attempt = try ResetAttempt.prepare(existing: nil, state: state, confirmed: true, now: now)!
        let restored = try JSONDecoder().decode(ResetAttempt.self, from: JSONEncoder().encode(attempt))
        check(try ResetAttempt.prepare(existing: restored, state: QuotaState(), confirmed: true, now: now) == attempt, "reset restart retry preserves key and selected credit")
        let data = try SelfTests.fixture(); let credentials = try QuotaCredentials.read(data, expectedKey: Identity.read(data).key)
        var p = ResetProtocol(credentials: credentials, attempt: attempt)
        _ = try p.receive(["id": 1, "result": [:]])
        if case .send(let messages) = try p.receive(["id": 2, "result": ["type": "chatgptAuthTokens"]]) {
            let params = messages[0]["params"] as! [String: Any]
            check(messages[0]["method"] as? String == "account/rateLimitResetCredit/consume" && params["idempotencyKey"] as? String == attempt.idempotencyKey && params["creditId"] as? String == "fixture-card", "reset sends exactly one selected credit with durable key")
        } else { check(false, "reset sends explicit consume") }
        if case .result(let result) = try p.receive(["id": 3, "result": ["outcome": "alreadyRedeemed"]]) {
            check(result == .alreadyRedeemed, "reset duplicate acknowledged without a new attempt")
        } else { check(false, "reset confirmed result") }
        if case .ignore = try p.receive(["id": 2, "result": ["type": "chatgptAuthTokens"]]) { check(true, "reset completed protocol sends no further consume") }
        else { check(false, "reset completed protocol sends no further consume") }
        func parse(_ raw: [String: Any]) throws -> QuotaState { QuotaState(snapshot: try QuotaSnapshot.parse(raw, now: now)) }
        check(try parse([:]).snapshot?.resetCredits == nil, "reset unsupported response stays unknown, not zero")
        for invalid: Any in [-1, 1.5, true, "2", NSNull()] {
            check(try parse(["rateLimitResetCredits": ["availableCount": invalid]]).snapshot?.resetCredits == nil, "reset malformed count stays unknown")
        }
        check(try !parse(["rateLimitResetCredits": ["availableCount": 0]]).canStartReset(now: now), "reset zero balance disables use")
        check(!state.canStartReset(now: now.addingTimeInterval(300)) && !state.canStartReset(now: now.addingTimeInterval(-1)), "reset stale or backward-clock data blocks new use")
        check(!QuotaState(snapshot: quota, error: "offline").canStartReset(now: now), "reset failed refresh blocks new use")
        do { _ = try ResetAttempt.prepare(existing: nil, state: state, confirmed: true, now: now, lastResetAt: now); check(false, "reset cross-instance stale snapshot blocked") }
        catch { check(true, "reset cross-instance stale snapshot blocked") }
        let expired = try parse(["rateLimitResetCredits": ["availableCount": 1, "credits": [["id": "expired", "status": "available", "resetType": "codexRateLimits", "expiresAt": 1_899_999_999]]]])
        check(!expired.canStartReset(now: now), "reset expired card waits for fresh official data")
        for (raw, label) in [(NSNull() as Any, "无到期限制"), ("invalid" as Any, "部分有效期待确认")] {
            let cards = ResetCredits.parse(["availableCount": 1, "credits": [["id": "a", "status": "available", "resetType": "codexRateLimits", "expiresAt": raw]]])!
            check(cards.expiryLabel(now: now) == label, "reset explicit null differs from malformed expiry")
        }
        for value in ["reset", "nothingToReset", "noCredit", "alreadyRedeemed"] {
            var p = ResetProtocol(credentials: credentials, attempt: attempt)
            _ = try p.receive(["id": 1, "result": [:]]); _ = try p.receive(["id": 2, "result": ["type": "chatgptAuthTokens"]])
            if case .result(let outcome) = try p.receive(["id": 3, "result": ["outcome": value]]) { check(outcome.rawValue == value, "reset distinct backend outcome: " + value) }
            else { check(false, "reset known outcome") }
        }
        var failure = ResetProtocol(credentials: credentials, attempt: attempt)
        do { _ = try failure.receive(["id": 1, "error": ["code": -1, "message": "SECRET-fixture"]]); check(false, "reset errors hidden") }
        catch { check(!error.localizedDescription.contains("SECRET"), "reset raw service errors hidden") }
        let paths = AppPaths(root: root, codexHome: root.appendingPathComponent("live-fixture"))
        let vault = MemoryVault(); let identity = try Identity.read(data)
        var library = SwitchLibrary(); library.accounts = [SavedAccount(id: UUID(), identityKey: identity.key, label: "Fixture", email: "fixture@example.com", plan: "plus", savedAt: now, color: 0, resetAttempt: attempt)]
        try SecureFile.saveLibrary(library, to: paths.metadata); try SecureFile.write(data, to: paths.auth)
        let model = SwitcherModel(paths: paths, vault: vault); model.saveCurrent()
        check(try SecureFile.loadLibrary(paths.metadata).accounts.first?.resetAttempt == attempt, "reset saving fresh login preserves pending attempt on disk")
        let cli = root.appendingPathComponent("reset-fixture-cli")
        let script = """
        #!/bin/sh
        test "$HOME" = "$CODEX_HOME" || exit 4
        test "$CODEX_SQLITE_HOME" = "$CODEX_HOME/state" || exit 5
        test ! -e "$CODEX_HOME/auth.json" || exit 6
        IFS= read -r line
        printf '%s\\n' '{"id":1,"result":{}}'
        IFS= read -r line
        IFS= read -r line
        printf '%s\\n' '{"id":2,"result":{"type":"chatgptAuthTokens"}}'
        IFS= read -r line
        case "$line" in *rateLimitResetCredit*consume*) ;; *) exit 7;; esac
        case "$line" in *\(attempt.idempotencyKey)*) ;; *) exit 8;; esac
        printf '%s\\n' '{"id":3,"result":{"outcome":"alreadyRedeemed"}}'
        """
        try Data(script.utf8).write(to: cli); chmod(cli.path, 0o700)
        let result = try await QuotaBroker.consumeReset(cli: cli, root: root, auth: data, expectedKey: identity.key, attempt: restored)
        check(result == .alreadyRedeemed, "reset isolated child roundtrip preserves persisted request key")
        let slow = root.appendingPathComponent("reset-slow-cli")
        try Data("#!/bin/sh\nexec /bin/sleep 5\n".utf8).write(to: slow); chmod(slow.path, 0o700)
        do { _ = try await QuotaBroker.consumeReset(cli: slow, root: root, auth: data, expectedKey: identity.key, attempt: attempt, timeout: 0.1); check(false, "reset timeout") }
        catch { check(try SecureFile.loadLibrary(paths.metadata).accounts.first?.resetAttempt == attempt, "reset timeout leaves durable request for retry") }
        check(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("reset-requests").path).isEmpty, "reset success and timeout clean isolated child homes")
        check(try SecureFile.read(paths.auth) == data, "reset leaves current login bytes unchanged")
    }
}
