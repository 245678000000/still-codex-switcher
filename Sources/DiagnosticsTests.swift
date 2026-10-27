import Foundation
import Darwin
@MainActor enum DiagnosticsTests {
    static func run(_ check: (Bool, String) -> Void, root: URL) async throws {
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let unknown = DiagnosticReport.fromQuota(QuotaSnapshot(fiveHours: nil, sevenDays: nil, fetchedAt: now))
        check(unknown.checks[0].level == .unknown, "diagnostics absent windows unknown, never full")
        let empty = DiagnosticReport.fromQuota(QuotaSnapshot(fiveHours: QuotaWindow(remaining: 0, resetsAt: now.addingTimeInterval(3600)), sevenDays: nil, fetchedAt: now))
        check(empty.checks[0].level == .attention && empty.summary == "有项目需要处理", "diagnostics exhausted quota needs attention")
        check(!empty.isStale(now: now) && empty.isStale(now: now.addingTimeInterval(300)) && empty.isStale(now: now.addingTimeInterval(-1)), "diagnostics timestamp freshness")
        let auth = try SelfTests.fixture(); let key = try Identity.read(auth).key
        let credentials = try QuotaCredentials.read(auth, expectedKey: key)
        func begin() throws -> DiagnosticProtocol {
            var state = DiagnosticProtocol(credentials: credentials)
            if case .send(let login) = try state.receive(["id": 1, "result": [:]], now: now) {
                let encoded = String(decoding: try JSONSerialization.data(withJSONObject: login), as: UTF8.self)
                check(encoded.contains("test-workspace-a") && !encoded.contains("fixture-refresh"), "diagnostics selected workspace and no refresh token")
            } else { check(false, "diagnostics initializes isolated login") }
            if case .send(let next) = try state.receive(["id": 2, "result": ["type": "chatgptAuthTokens"]], now: now) {
                check(next[0]["method"] as? String == "account/rateLimits/read", "diagnostics token load requires service read, not a healthy report")
            } else { check(false, "diagnostics service read required") }
            return state
        }
        var state = try begin()
        _ = try state.receive(["id": 3, "result": ["rateLimits": ["primary": ["usedPercent": 20, "windowDurationMins": 300]]]], now: now)
        if case .send = try state.receive(["id": 4, "result": ["data": [["model": "example-a"], ["model": "hidden", "hidden": true]], "nextCursor": "p2"]], now: now) {
            check(true, "diagnostics model list paginates")
        } else { check(false, "diagnostics model list paginates") }
        if case .result(let report) = try state.receive(["id": 4, "result": ["data": [["model": "example-a"], ["model": "example-b"]]]], now: now) {
            check(report.models == ["example-a", "example-b"] && report.quota?.fiveHours?.remaining == 80, "diagnostics reports deduplicated catalog and real quota")
            check(report.checks.last!.detail.contains("尚未验证实际推理"), "diagnostics catalog not model execution proof")
        } else { check(false, "diagnostics final result") }
        for code in [401, 403, 429, -32601, -1] {
            var failed = try begin()
            _ = try failed.receive(["id": 3, "error": ["code": code, "message": "SECRET-server-payload"]], now: now)
            if case .result(let report) = try failed.receive(["id": 4, "result": ["data": [[String: Any]]()]], now: now) {
                check(report.summary == "有项目需要处理" && !report.checks.map(\.detail).joined().contains("SECRET"), "diagnostics service failure redacted")
            } else { check(false, "diagnostics failure report") }
        }
        var refresh = try begin()
        if case .result(let report) = try refresh.receive(["id": 90, "method": "account/chatgptAuthTokens/refresh"], now: now) {
            check(report.summary == "有项目需要处理", "diagnostics refresh stops without renewal")
        } else { check(false, "diagnostics refresh stops") }
        var repeated = try begin(); _ = try repeated.receive(["id": 3, "result": [:]], now: now)
        let page: [String: Any] = ["id": 4, "result": ["data": [["model": "example-a"]], "nextCursor": "same"]]
        _ = try repeated.receive(page, now: now)
        if case .result(let report) = try repeated.receive(page, now: now) { check(report.checks.last!.level == .unknown, "diagnostics repeated cursor labelled partial") }
        else { check(false, "diagnostics repeated cursor bounded") }
        let folder = QuotaBroker.canonicalSystemURL(root)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let cli = folder.appendingPathComponent("fixture-cli")
        let script = """
        #!/bin/sh
        [ "$HOME" = "$CODEX_HOME" ] || exit 9
        [ "$CODEX_SQLITE_HOME" = "$CODEX_HOME/state" ] || exit 10
        [ ! -f "$CODEX_HOME/auth.json" ] || exit 11
        IFS= read -r line
        printf '%s\\n' '{"id":1,"result":{}}'
        IFS= read -r line
        IFS= read -r line
        printf '%s\\n' '{"id":2,"result":{"type":"chatgptAuthTokens"}}'
        IFS= read -r line
        case "$line" in *account*rateLimits*read*) ;; *) exit 12;; esac
        printf '%s\\n' '{"id":3,"result":{"rateLimits":{"primary":{"usedPercent":20,"windowDurationMins":300}}}}'
        IFS= read -r line
        case "$line" in *model*list*) ;; *) exit 13;; esac
        printf '%s\\n' '{"id":4,"result":{"data":[{"model":"example-model"}]}}'
        """
        try Data(script.utf8).write(to: cli); chmod(cli.path, 0o700)
        let report = try await QuotaBroker.diagnose(cli: cli, root: folder, auth: auth, expectedKey: key)
        check(report.models == ["example-model"] && report.quota?.fiveHours?.remaining == 80, "diagnostics real pipes, isolated home and database, read-only requests")
        let slow = folder.appendingPathComponent("slow-cli")
        try Data("#!/bin/sh\nexec /bin/sleep 5\n".utf8).write(to: slow); chmod(slow.path, 0o700)
        let task = Task { try await QuotaBroker.diagnose(cli: slow, root: folder, auth: auth, expectedKey: key) }
        try await Task.sleep(for: .milliseconds(100)); task.cancel()
        do { _ = try await task.value; check(false, "diagnostics running request cancelled") } catch { check(error is CancellationError, "diagnostics running request cancelled") }
        do { _ = try await QuotaBroker.diagnose(cli: slow, root: folder, auth: auth, expectedKey: key, timeout: 0.1); check(false, "diagnostics timeout") }
        catch { check(error.localizedDescription.contains("超时"), "diagnostics timeout") }
        check(try FileManager.default.contentsOfDirectory(atPath: folder.appendingPathComponent("diagnostic-queries").path).isEmpty, "diagnostics own temporary directories cleaned on every exit")
        check(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("auth.json").path), "diagnostics credentials never stored on disk")
    }
}
