import Foundation
import Darwin

@MainActor enum QuotaTests {
    static func run(_ check: (Bool, String) -> Void, root: URL) async throws {
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        func parse(_ text: String) throws -> QuotaSnapshot { try QuotaSnapshot.parse(JSONSerialization.jsonObject(with: Data(text.utf8)) as! [String: Any], now: now) }
        func rejects(_ name: String, _ action: () throws -> Void) { do { try action(); check(false, name) } catch { check(true, name) } }
        let windows = #""primary":{"usedPercent":24.5,"windowDurationMins":300,"resetsAt":1900003600},"secondary":{"usedPercent":80,"windowDurationMins":10080,"resetsAt":1900400000}"#
        let q = try parse("{\"rateLimits\":{\"limitId\":\"codex\"," + windows + "}}")
        check(q.fiveHours?.remaining == 75.5 && q.sevenDays?.remaining == 20, "quota remaining, not used percentage")
        check(q.fiveHours?.resetsAt == now.addingTimeInterval(3600) && q.fetchedAt == now, "quota Unix seconds and fetch timestamp")
        let preferred = try parse("{\"rateLimitsByLimitId\":{\"codex\":{" + windows + "}},\"rateLimits\":{\"primary\":{\"usedPercent\":99,\"windowDurationMins\":300}}}")
        check(preferred.fiveHours?.remaining == 75.5, "quota Codex map preferred")
        for text in ["{}", "{\"rateLimits\":null}", "{\"rateLimitsByLimitId\":{\"other\":{" + windows + "}},\"rateLimits\":{" + windows + "}}", "{\"rateLimitsByLimitId\":{},\"rateLimits\":{" + windows + "}}", "{\"rateLimits\":{\"limitId\":\"other\"," + windows + "}}"] {
            let missing = try parse(text); check(missing.fiveHours == nil && missing.sevenDays == nil, "quota missing or other bucket unknown")
        }
        check(try parse("{\"rateLimitsByLimitId\":null,\"rateLimits\":{" + windows + "}}").fiveHours != nil, "quota null map legacy fallback")
        let swapped = try parse(#"{"rateLimits":{"primary":{"usedPercent":20,"windowDurationMins":10080},"secondary":{"usedPercent":60,"windowDurationMins":300}}}"#)
        check(swapped.fiveHours?.remaining == 40 && swapped.sevenDays?.remaining == 80, "quota matches duration not position")
        for window in ["null", "{}", #"{"usedPercent":0}"#, #"{"usedPercent":null,"windowDurationMins":300}"#, #"{"usedPercent":"10","windowDurationMins":300}"#, #"{"usedPercent":true,"windowDurationMins":300}"#, #"{"usedPercent":0,"windowDurationMins":60}"#, #"{"usedPercent":0,"windowDurationMins":"300"}"#] {
            check(try parse("{\"rateLimits\":{\"primary\":" + window + "}}").fiveHours == nil, "quota invalid window never means full")
        }
        check(try parse(#"{"rateLimits":{"primary":{"usedPercent":120,"windowDurationMins":300}}}"#).fiveHours?.remaining == 0, "quota used high clamped")
        check(try parse(#"{"rateLimits":{"primary":{"usedPercent":-10,"windowDurationMins":300}}}"#).fiveHours?.remaining == 100, "quota used low clamped")
        check(try parse(#"{"rateLimits":{"primary":{"usedPercent":10,"windowDurationMins":300,"resetsAt":9223372036854775807}}}"#).fiveHours?.resetsAt == nil, "quota bad reset unknown")
        check(try parse(#"{"rateLimits":{"primary":{"usedPercent":1,"windowDurationMins":300},"secondary":{"usedPercent":2,"windowDurationMins":300}}}"#).fiveHours == nil, "quota duplicate duration ambiguous")
        rejects("quota malformed map rejected") { _ = try parse(#"{"rateLimitsByLimitId":[]}"#) }
        check(QuotaSnapshot.number(Double.nan) == nil && QuotaSnapshot.number(Double.infinity) == nil, "quota nonfinite numbers rejected")
        let state = QuotaState(snapshot: q)
        check(!state.isStale(now: now) && state.isStale(now: now.addingTimeInterval(300)), "quota stale after five minutes")
        check(state.isStale(now: now.addingTimeInterval(-1)), "quota clock rollback stale")
        var failed = state; failed.error = "fixture offline"
        check(failed.isStale(now: now) && failed.snapshot == q && failed.status(now: now).contains("上次结果"), "quota failure retains labelled snapshot")
        let expired = QuotaWindow(remaining: 12, resetsAt: now.addingTimeInterval(-1))
        let expiredState = QuotaState(snapshot: QuotaSnapshot(fiveHours: expired, sevenDays: nil, fetchedAt: now))
        check(expiredState.isStale(now: now) && expired.remaining == 12 && expired.resetLabel(now: now).contains("待刷新"), "quota crossed reset never invents full")
        check(q.fiveHours?.percent == "75.5%" && q.sevenDays?.percent == "20%", "quota presentation")
        check(QuotaWindow(remaining: 0, resetsAt: nil).resetLabel().contains("未提供"), "quota missing reset time")
        check(QuotaState().status(now: now) == "待刷新", "quota initial state unknown")
        var loading = state; loading.loading = true; check(loading.status(now: now).contains("正在刷新"), "quota loading status")
        let attempt = QuotaState(attemptedAt: now)
        check(!attempt.due(now: now.addingTimeInterval(29), automatic: false) && attempt.due(now: now.addingTimeInterval(30), automatic: false), "quota manual cooldown")
        check(!attempt.due(now: now.addingTimeInterval(299), automatic: true) && attempt.due(now: now.addingTimeInterval(300), automatic: true), "quota automatic cooldown")
        let a = try SelfTests.fixture(); let identity = try Identity.read(a)
        let creds = try QuotaCredentials.read(a, expectedKey: identity.key)
        check(creds.accountID == "test-workspace-a" && creds.accessToken == "fixture-access-only", "quota credentials use selected workspace")
        check(!String(describing: creds).contains("fixture-access") && !String(reflecting: creds).contains("fixture-access"), "quota credential diagnostics redacted")
        rejects("quota mismatched identity rejected") { _ = try QuotaCredentials.read(a, expectedKey: "other") }
        var protocolState = QuotaProtocol(credentials: creds)
        let caps = (QuotaProtocol.initialize["params"] as! [String: Any])["capabilities"] as! [String: Bool]
        check(caps["experimentalApi"] == true, "quota experimental capability")
        if case .ignore = try protocolState.receive(["id": 99, "result": [:]]) { check(true, "quota unrelated reply ignored") } else { check(false, "quota unrelated reply ignored") }
        if case .send(let messages) = try protocolState.receive(["id": 1, "result": [:]]) {
            let login = messages[1]["params"] as! [String: Any]
            check(messages[0]["method"] as? String == "initialized" && login["type"] as? String == "chatgptAuthTokens", "quota initialize then ephemeral auth")
            check(login["chatgptAccountId"] as? String == "test-workspace-a", "quota protocol selected account")
            let encoded = String(data: try JSONSerialization.data(withJSONObject: messages), encoding: .utf8)!
            check(!encoded.contains("fixture-refresh") && !encoded.contains("refresh_token"), "quota protocol sends no refresh token")
        } else { check(false, "quota protocol initial reply") }
        if case .send(let messages) = try protocolState.receive(["id": 2, "result": ["type": "chatgptAuthTokens"]]) { check(messages.count == 1 && messages[0]["method"] as? String == "account/rateLimits/read", "quota only read method requested") }
        else { check(false, "quota read requested") }
        if case .result(let returned) = try protocolState.receive(["id": 3, "result": ["rateLimits": ["primary": ["usedPercent": 25, "windowDurationMins": 300]]]], now: now) { check(returned.fiveHours?.remaining == 75, "quota protocol result parsed") }
        else { check(false, "quota protocol result parsed") }
        rejects("quota external token renewal not performed") { _ = try protocolState.receive(["method": "account/chatgptAuthTokens/refresh", "id": 77]) }
        var unsafe = QuotaProtocol(credentials: creds)
        do { _ = try unsafe.receive(["id": 1, "error": ["code": -1, "message": "SECRET-fixture"]]); check(false, "quota raw errors hidden") }
        catch { check(!error.localizedDescription.contains("SECRET-fixture"), "quota raw errors hidden") }
        let b = try SelfTests.fixture("fixture-b", account: "workspace-b")
        check(try QuotaCredentials.read(b, expectedKey: Identity.read(b).key).accountID == "workspace-b" && creds.accountID == "test-workspace-a", "quota identities stay independent")

        // Real subprocess transport exercised with a tiny local stdio fixture; no network or real auth.
        let fixtureRoot = QuotaBroker.canonicalSystemURL(root); try QuotaBroker.privateDirectory(fixtureRoot)
        try QuotaBroker.checkPath(URL(fileURLWithPath: "/var/folders"))
        try QuotaBroker.checkPath(URL(fileURLWithPath: "/private/var/folders"))
        check(true, "quota physical and system alias paths accepted")
        let cli = fixtureRoot.appendingPathComponent("quota-fixture-cli")
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
        printf '%s\\n' '{"id":3,"result":{"rateLimits":{"primary":{"usedPercent":24,"windowDurationMins":300},"secondary":{"usedPercent":58,"windowDurationMins":10080}}}}'
        """
        try Data(script.utf8).write(to: cli); chmod(cli.path, 0o700)
        let actual = try await QuotaBroker.read(cli: cli, root: fixtureRoot, auth: a, expectedKey: identity.key)
        check(actual.fiveHours?.remaining == 76 && actual.sevenDays?.remaining == 42, "quota subprocess roundtrip")
        let queries = fixtureRoot.appendingPathComponent("quota-queries")
        check(try FileManager.default.contentsOfDirectory(atPath: queries.path).isEmpty, "quota successful child cleaned")
        let slow = fixtureRoot.appendingPathComponent("quota-slow-cli")
        try Data("#!/bin/sh\nexec /bin/sleep 5\n".utf8).write(to: slow); chmod(slow.path, 0o700)
        let task = Task { try await QuotaBroker.read(cli: slow, root: fixtureRoot, auth: a, expectedKey: identity.key) }
        try await Task.sleep(for: .milliseconds(100)); task.cancel()
        do { _ = try await task.value; check(false, "quota running child cancelled") } catch { check(error is CancellationError, "quota running child cancelled") }
        check(try FileManager.default.contentsOfDirectory(atPath: queries.path).isEmpty, "quota cancelled child cleaned")
        do { _ = try await QuotaBroker.read(cli: slow, root: fixtureRoot, auth: a, expectedKey: identity.key, timeout: 0.1); check(false, "quota deadline enforced") }
        catch { check(error.localizedDescription.contains("超时"), "quota deadline enforced") }
        check(try FileManager.default.contentsOfDirectory(atPath: queries.path).isEmpty, "quota timed-out child cleaned")
        do { _ = try await QuotaBroker.read(cli: fixtureRoot.appendingPathComponent("missing"), root: fixtureRoot, auth: a, expectedKey: identity.key); check(false, "quota spawn failure") }
        catch { check(true, "quota spawn failure") }
        check(try FileManager.default.contentsOfDirectory(atPath: queries.path).isEmpty, "quota failed spawn cleaned")
        let link = fixtureRoot.appendingPathComponent("linked-root")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fixtureRoot)
        rejects("quota symlink directory rejected") { try QuotaBroker.checkPath(link.appendingPathComponent("quota-queries")) }
        check(!FileManager.default.fileExists(atPath: fixtureRoot.appendingPathComponent("auth.json").path), "quota no credential file persisted")
    }
}
