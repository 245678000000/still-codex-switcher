import Foundation
import Darwin

@MainActor enum WarmupTests {
    static func run(_ check: (Bool, String) -> Void, root: URL) async throws {
        func rejects(_ name: String, _ action: () throws -> Void) { do { try action(); check(false, name) } catch { check(true, name) } }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let reset = now.addingTimeInterval(-120)
        func snapshot(_ end: Date? = nil, week: Double = 50, fetched: Date? = nil) -> QuotaSnapshot {
            QuotaSnapshot(fiveHours: QuotaWindow(remaining: 0, resetsAt: end ?? reset), sevenDays: QuotaWindow(remaining: week, resetsAt: now.addingTimeInterval(86_400)), fetchedAt: fetched ?? now)
        }
        var r = WarmupRecord()
        check(WarmupPolicy.reason(r, snapshot: snapshot(), now: now) != nil, "warmup default off")
        r.enabled = true
        check(WarmupPolicy.reason(r, snapshot: snapshot(), now: now) == nil, "warmup due eligible window")
        check(WarmupPolicy.reason(r, snapshot: nil, now: now) != nil, "warmup unknown quota skips")
        check(WarmupPolicy.reason(r, snapshot: snapshot(fetched: now.addingTimeInterval(-90)), now: now) != nil, "warmup stale quota skips")
        check(WarmupPolicy.reason(r, snapshot: snapshot(fetched: now.addingTimeInterval(1)), now: now) != nil, "warmup clock rollback skips")
        check(WarmupPolicy.reason(r, snapshot: snapshot(now.addingTimeInterval(1)), now: now) != nil, "warmup active window skips")
        check(WarmupPolicy.reason(r, snapshot: snapshot(now.addingTimeInterval(-59)), now: now) != nil, "warmup reset grace period")
        check(WarmupPolicy.reason(r, snapshot: snapshot(week: 0.5), now: now) != nil, "warmup weekly reserve")
        check(WarmupPolicy.reason(r, snapshot: QuotaSnapshot(fiveHours: snapshot().fiveHours, sevenDays: nil, fetchedAt: now), now: now) != nil, "warmup unknown weekly balance skips")
        check(WarmupPolicy.reason(r, snapshot: QuotaSnapshot(fiveHours: nil, sevenDays: snapshot().sevenDays, fetchedAt: now), now: now) != nil, "warmup plans without five hour window skip")
        r.processedReset = reset
        check(WarmupPolicy.reason(r, snapshot: snapshot(), now: now) != nil, "warmup same window deduplicated")
        check(WarmupPolicy.reason(r, snapshot: snapshot(reset.addingTimeInterval(-100)), now: now) != nil, "warmup older reset deduplicated")
        check(WarmupPolicy.reason(r, snapshot: snapshot(), now: now, manual: true) == nil, "warmup explicit manual retry after confirmation allowed")
        r.lastAttempt = now.addingTimeInterval(-100)
        check(WarmupPolicy.reason(r, snapshot: snapshot(reset.addingTimeInterval(1)), now: now) != nil, "warmup changed reset still bounded by five hour cooldown")
        check(WarmupPolicy.reason(r, snapshot: snapshot(), now: now.addingTimeInterval(-60), manual: true) != nil, "warmup manual cooldown bounded")
        r.lastAttempt = nil; r.processedReset = nil; r.paused = true
        check(WarmupPolicy.reason(r, snapshot: snapshot(), now: now) != nil, "warmup failures pause automatic mode")
        let data = try SelfTests.fixture(); let key = try Identity.read(data).key
        let creds = try QuotaCredentials.read(data, expectedKey: key)
        func quota(_ end: Date) -> [String: Any] {
            ["rateLimits": ["limitId": "codex", "primary": ["windowDurationMins": 300, "usedPercent": 100, "resetsAt": Int(end.timeIntervalSince1970)], "secondary": ["windowDurationMins": 10080, "usedPercent": 50, "resetsAt": Int(now.timeIntervalSince1970 + 86_400)]]]
        }
        func loggedIn() throws -> WarmupProtocol {
            var p = WarmupProtocol(credentials: creds, directory: "/fixture/private", reset: reset)
            if case .send(let msgs) = try p.receive(["id": 1, "result": [:]], now: now) {
                let encoded = String(data: try JSONSerialization.data(withJSONObject: msgs), encoding: .utf8)!
                check(encoded.contains("fixture-access-only") && !encoded.contains("fixture-refresh") && !encoded.contains("refresh_token"), "warmup sends only access token over pipe")
            } else { check(false, "warmup initialized") }
            _ = try p.receive(["id": 2, "result": ["type": "chatgptAuthTokens"]], now: now)
            return p
        }
        var shifted = try loggedIn()
        if case .result(let result) = try shifted.receive(["id": 3, "result": quota(now.addingTimeInterval(18_000))], now: now) {
            check(!result.sent && !result.confirmed, "warmup server recheck skips already active window")
        } else { check(false, "warmup recheck") }
        var p = try loggedIn()
        _ = try p.receive(["id": 3, "result": quota(reset)], now: now)
        var missing = p
        rejects("warmup missing selected model stops without substitution") { _ = try missing.receive(["id": 4, "result": ["data": []]], now: now) }
        let model: [String: Any] = ["model": WarmupPolicy.model, "supportedReasoningEfforts": [["reasoningEffort": "low"]]]
        if case .send(let msgs) = try p.receive(["id": 4, "result": ["data": [model]]], now: now) {
            let params = msgs[0]["params"] as! [String: Any]
            check(params["ephemeral"] as? Bool == true && params["sandbox"] as? String == "read-only" && params["approvalPolicy"] as? String == "never", "warmup isolated ephemeral read-only thread")
        }
        let thread: [String: Any] = ["thread": ["id": "thread-fixture", "ephemeral": true], "model": WarmupPolicy.model, "modelProvider": "openai", "cwd": "/fixture/private", "approvalPolicy": "never", "sandbox": ["type": "readOnly"]]
        var wrong = p; var bad = thread; bad["cwd"] = "/real-user-home"
        rejects("warmup unexpected thread location stops before turn") { _ = try wrong.receive(["id": 5, "result": bad], now: now) }
        if case .send(let msgs) = try p.receive(["id": 5, "result": thread], now: now) {
            let params = msgs[0]["params"] as! [String: Any]
            check(msgs.count == 1 && msgs[0]["method"] as? String == "turn/start" && params["effort"] as? String == "low", "warmup exactly one low effort turn")
            check((params["sandboxPolicy"] as? [String: Any])?["access"] != nil, "warmup tool reads restricted to fixture")
        }
        var renew = p
        rejects("warmup token refresh request stops instead of rotating") { _ = try renew.receive(["id": 50, "method": "account/chatgptAuthTokens/refresh"]) }
        var tool = p
        rejects("warmup extra server tool request stops") { _ = try tool.receive(["id": 51, "method": "item/commandExecution/requestApproval"]) }
        var failed = p
        do { _ = try failed.receive(["id": 6, "error": ["message": "SECRET TOKEN"]]); check(false, "warmup raw errors redacted") }
        catch { check(!error.localizedDescription.contains("SECRET"), "warmup raw errors redacted") }
        let completion: [String: Any] = ["method": "turn/completed", "params": ["threadId": "thread-fixture", "turn": ["id": "turn-fixture", "status": "completed"]]]
        _ = try p.receive(completion, now: now) // notification may race the response
        if case .send(let msgs) = try p.receive(["id": 6, "result": ["turn": ["id": "turn-fixture"]]], now: now) {
            check(msgs[0]["method"] as? String == "account/rateLimits/read", "warmup waits for completion then verifies limits")
        } else { check(false, "warmup completion ordering") }
        var unconfirmed = p
        if case .result(let value) = try unconfirmed.receive(["id": 7, "result": quota(reset)], now: now) { check(value.sent && !value.confirmed, "warmup unchanged reset is not reported activated") }
        if case .result(let value) = try p.receive(["id": 7, "result": quota(now.addingTimeInterval(18_000))], now: now) { check(value.sent && value.confirmed, "warmup new reset confirmed from server") }
        try QuotaBroker.privateDirectory(root)
        let cli = root.appendingPathComponent("fake-warmup-cli")
        let script = #"""
        #!/usr/bin/python3
        import os,sys,json,time
        home=os.environ['CODEX_HOME']
        assert home==os.environ['HOME']==os.getcwd()
        assert 'OPENAI_API_KEY' not in os.environ and 'CODEX_ACCESS_TOKEN' not in os.environ
        assert not os.path.exists(home+'/auth.json')
        assert 'features.shell_tool=false' in sys.argv and 'features.apps=false' in sys.argv
        def send(obj): print(json.dumps(obj),flush=True)
        reads=0
        for line in sys.stdin:
            q=json.loads(line); m=q.get('method'); n=q.get('id'); a=q.get('params',{})
            assert 'refresh_token' not in line and 'fixture-refresh' not in line
            if m=='initialize': send({'id':n,'result':{}})
            elif m=='initialized': pass
            elif m=='account/login/start':
                assert a['accessToken']=='fixture-access-only' and a['chatgptAccountId']=='test-workspace-a'
                send({'id':n,'result':{'type':'chatgptAuthTokens'}})
            elif m=='account/rateLimits/read':
                reads+=1
                reset=int(time.time())+18000 if reads>1 else int(time.time())-120
                send({'id':n,'result':{'rateLimits':{'limitId':'codex','primary':{'windowDurationMins':300,'usedPercent':1,'resetsAt':reset},'secondary':{'windowDurationMins':10080,'usedPercent':2,'resetsAt':int(time.time())+86400}}}})
            elif m=='model/list': send({'id':n,'result':{'data':[{'model':'gpt-6-luna','supportedReasoningEfforts':[{'reasoningEffort':'low'}]}]}})
            elif m=='thread/start':
                assert a['ephemeral'] and a['sandbox']=='read-only' and a['cwd']==home
                send({'id':n,'result':{'thread':{'id':'t','ephemeral':True},'model':'gpt-6-luna','modelProvider':'openai','cwd':home,'approvalPolicy':'never','sandbox':{'type':'readOnly'}}})
            elif m=='turn/start':
                assert a['input']==[{'type':'text','text':'回复ok'}]
                send({'id':n,'result':{'turn':{'id':'u','status':'inProgress'}}})
                send({'method':'turn/completed','params':{'threadId':'t','turn':{'id':'u','status':'completed'}}})
            else: raise RuntimeError('unexpected method')
        """#
        // Use a fixed reset for the process and caller, independent of second-boundary crossings.
        let processReset = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970) - 120)
        let fixedScript = script.replacingOccurrences(of: "int(time.time())-120", with: String(Int(processReset.timeIntervalSince1970)))
        try Data(fixedScript.utf8).write(to: cli); chmod(cli.path, 0o700)
        let result = try await QuotaBroker.warmup(cli: cli, root: root, auth: data, expectedKey: key, reset: processReset)
        check(result.sent && result.confirmed, "warmup subprocess synthetic end-to-end")
        let requests = root.appendingPathComponent("warmup-requests")
        check(try FileManager.default.contentsOfDirectory(atPath: requests.path).isEmpty, "warmup child private files cleaned")
        let slow = root.appendingPathComponent("slow-cli")
        try Data("#!/bin/sh\nexec /bin/sleep 10\n".utf8).write(to: slow); chmod(slow.path, 0o700)
        do { _ = try await QuotaBroker.warmup(cli: slow, root: root, auth: data, expectedKey: key, reset: processReset, timeout: 0.1); check(false, "warmup deadline") }
        catch { check(true, "warmup deadline") }
        check(try FileManager.default.contentsOfDirectory(atPath: requests.path).isEmpty, "warmup timeout cleans child")
        let paths = AppPaths(root: root.appendingPathComponent("model"), codexHome: root.appendingPathComponent("live-fixture"))
        try SecureFile.write(data, to: paths.auth)
        let vault = MemoryVault(); let modelObject = SwitcherModel(paths: paths, vault: vault)
        modelObject.saveCurrent()
        let id = modelObject.library.accounts[0].id
        check(modelObject.library.accounts[0].warmup == nil, "warmup existing accounts remain disabled")
        var lib = modelObject.library; lib.accounts[0].warmup = WarmupRecord(enabled: true)
        try SecureFile.saveLibrary(lib, to: paths.metadata); modelObject.library = lib
        let currentSnapshot = QuotaSnapshot(fiveHours: QuotaWindow(remaining: 0, resetsAt: processReset), sevenDays: QuotaWindow(remaining: 50, resetsAt: Date().addingTimeInterval(86_400)), fetchedAt: Date())
        let originalVault = vault.values
        await modelObject.attemptWarmup(lib.accounts[0], snapshot: currentSnapshot, cli: cli, manual: false)
        let saved = try SecureFile.loadLibrary(paths.metadata)
        check(saved.accounts[0].warmup?.processedReset == processReset && saved.accounts[0].warmup?.lastConfirmed != nil, "warmup model commits claim and verified outcome")
        check(try vault.values == originalVault && SecureFile.read(paths.auth) == data, "warmup never writes vault or active auth")
        let attempt = saved.accounts[0].warmup?.lastAttempt
        await modelObject.attemptWarmup(lib.accounts[0], snapshot: currentSnapshot, cli: cli, manual: false)
        check(try SecureFile.loadLibrary(paths.metadata).accounts[0].warmup?.lastAttempt == attempt, "warmup model duplicate request suppressed")
        let reopened = SwitcherModel(paths: paths, vault: vault)
        check(reopened.library.accounts[0].warmup == saved.accounts[0].warmup, "warmup dedup survives restart")
        reopened.pauseWarmupAfterQueryFailure(reopened.library.accounts[0], reason: "登录已过期")
        check(reopened.library.accounts[0].warmup?.paused == true && !reopened.hasAutoWarmup, "warmup quota query failure pauses background scheduler")
        reopened.library = saved; try SecureFile.saveLibrary(saved, to: paths.metadata)
        reopened.saveCurrent()
        check(reopened.library.accounts[0].id == id && reopened.library.accounts[0].warmup == saved.accounts[0].warmup, "warmup saving refreshed credentials preserves settings")
        var pendingLib = reopened.library; pendingLib.accounts[0].warmup = WarmupRecord(enabled: true)
        try SecureFile.saveLibrary(pendingLib, to: paths.metadata); reopened.library = pendingLib
        let task = Task { await reopened.attemptWarmup(pendingLib.accounts[0], snapshot: currentSnapshot, cli: slow, manual: false) }
        try await Task.sleep(for: .milliseconds(100))
        check(try SecureFile.loadLibrary(paths.metadata).accounts[0].warmup?.processedReset == processReset, "warmup claim persisted before network completion")
        let concurrent = SwitcherModel(paths: paths, vault: vault)
        concurrent.library = pendingLib // Simulate a second instance with stale UI metadata.
        let claim = try SecureFile.loadLibrary(paths.metadata).accounts[0].warmup
        await concurrent.attemptWarmup(pendingLib.accounts[0], snapshot: currentSnapshot, cli: cli, manual: true)
        check(try SecureFile.loadLibrary(paths.metadata).accounts[0].warmup == claim, "warmup second instance leaves durable claim unchanged")
        task.cancel(); await task.value
        check(!reopened.busy && reopened.library.accounts[0].warmup?.paused == true, "warmup cancellation pauses and releases operation lock")
        check(try FileManager.default.contentsOfDirectory(atPath: paths.root.appendingPathComponent("warmup-requests").path).isEmpty, "warmup model cancellation cleans private data")
    }
}
