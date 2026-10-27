using System.IO;
using System.Text.Json;
using Still.Core;

namespace Still.Tests;
public static class WarmupTests
{
    static JsonElement J(object value) => JsonSerializer.SerializeToElement(value);
    static JsonElement Reply(int id, object value) => J(new { id, result = value });
    static object Quota(DateTimeOffset now, double used = 0, double week = 20) => new
    {
        rateLimits = new { limitId = "codex", primary = new { usedPercent = used, windowDurationMins = 300, resetsAt = now.AddHours(5).ToUnixTimeSeconds() },
            secondary = new { usedPercent = week, windowDurationMins = 10080, resetsAt = now.AddDays(2).ToUnixTimeSeconds() } }
    };
    static object Models => new { data = new[] { new { model = WarmupPolicy.Model, hidden = false, supportedReasoningEfforts = new[] { new { reasoningEffort = "low" } } } } };
    static object Thread(string dir, string model = WarmupPolicy.Model, bool ephemeral = true, string sandbox = "readOnly") => new
        { thread = new { id = "thread-fixture", ephemeral }, model, modelProvider = "openai", cwd = dir, approvalPolicy = "never", sandbox = new { type = sandbox } };
    static JsonElement Complete(string id = "turn-fixture", string status = "completed", string thread = "thread-fixture") => J(new
        { method = "turn/completed", @params = new { threadId = thread, turn = new { id, status } } });
    static JsonElement Message(WarmupStep step, int index = 0) => J(step.Messages[index]);
    public static async Task Run(Action<bool, string> check)
    {
        var now = DateTimeOffset.FromUnixTimeSeconds(1900000000);
        var q = QuotaSnapshot.Parse(J(Quota(now)), now);
        var enabled = new WarmupRecord(Enabled: true, ScheduleVersion: WarmupPolicy.Version);
        void Reject(Action action, string name) { try { action(); check(false, name); } catch (UserError) { check(true, name); } }
        async Task RejectAsync(Func<Task> action, string name) { try { await action(); check(false, name); } catch { check(true, name); } }
        check(WarmupPolicy.Reason(new(), q, now) != null, "warmup defaults OFF");
        check(WarmupPolicy.Reason(enabled, q, now) == null, "warmup explicit opt-in permits first attempt");
        check(WarmupPolicy.Reason(enabled with { ScheduleVersion = 1 }, q, now) != null, "warmup changed rules require reconfirmation");
        check(WarmupPolicy.Reason(enabled with { Paused = true }, q, now) != null, "warmup paused record prevents automatic retry");
        check(WarmupPolicy.Reason(new(), q, now, true) == null, "warmup manual works with auto OFF and future reset");
        check(WarmupPolicy.Reason(enabled with { Paused = true }, q, now, true) == null, "warmup manual recovers paused account after confirmation");
        foreach (var bad in new QuotaSnapshot?[] { null, q with { FetchedAt = now.AddSeconds(-90) }, q with { FetchedAt = now.AddSeconds(1) },
            q with { FiveHours = null }, q with { FiveHours = new(0, now.AddHours(5)) }, q with { FiveHours = new(100, null) },
            q with { SevenDays = null }, q with { SevenDays = new(.9, now.AddDays(1)) }, q with { SevenDays = new(100, null) }, q with { SevenDays = new(50, now) } })
            check(WarmupPolicy.Reason(enabled, bad, now, true) != null, "warmup unknown/stale/exhausted quotas block even manual");
        check(WarmupPolicy.Reason(enabled, q with { SevenDays = new(1, now.AddDays(1)) }, now) == null, "warmup weekly threshold inclusive at 1 percent");
        check(WarmupPolicy.Reason(enabled with { LastAttempt = now.AddSeconds(-59) }, q, now, true) != null, "warmup manual 60 second cooldown");
        check(WarmupPolicy.Reason(enabled with { LastAttempt = now.AddSeconds(-60) }, q, now, true) == null, "warmup manual cooldown boundary");
        check(WarmupPolicy.Reason(enabled with { LastAttempt = now.AddHours(-4) }, q, now) != null, "warmup auto minimum five hours");
        check(WarmupPolicy.Reason(enabled with { LastAttempt = now.AddHours(1) }, q, now, true) != null, "warmup clock rollback blocks retry");
        check(WarmupPolicy.Reason(enabled with { LastAttempt = now.AddHours(-6), NextAt = now.AddHours(1) }, q, now) != null, "warmup respects next scheduled server anchor");
        check(WarmupPolicy.NextAfterSuccess(now, q) == now.AddSeconds(18060), "warmup cooldown includes one minute margin");
        check(WarmupPolicy.NextAfterSuccess(now, q with { FiveHours = new(80, now.AddHours(6)) }) == now.AddHours(6).AddMinutes(1), "warmup later server reset wins");
        var start = QuotaProcess.CreateStartInfo("fixture-cli", "fixture-home");
        check(start.Environment["CODEX_HOME"] == "fixture-home" && start.WorkingDirectory == "fixture-home" && start.CreateNoWindow && !start.UseShellExecute, "warmup private HOME cwd and no shell/window");
        check(start.RedirectStandardInput && start.RedirectStandardOutput && start.RedirectStandardError && start.ArgumentList.Contains("cli_auth_credentials_store=\"ephemeral\""), "warmup stdin transport and ephemeral credential store");
        check(new[] { "OPENAI_API_KEY", "CODEX_API_KEY", "CODEX_ACCESS_TOKEN", "OPENAI_BASE_URL", "CODEX_THREAD_ID", "CODEX_INTERNAL_ORIGINATOR_OVERRIDE" }.All(k => !start.Environment.ContainsKey(k)), "warmup child strips inherited account/provider overrides");
        var auth = TestSuite.Fixture(); var key = Identity.Read(auth).Key;
        WarmupProtocol StartTo(int stage = 5)
        {
            var p = new WarmupProtocol(QuotaCredentials.Read(auth, key), "fixture-dir");
            p.Receive(Reply(1, new { }), now);
            p.Receive(Reply(2, new { type = "chatgptAuthTokens" }), now);
            if (stage >= 4) p.Receive(Reply(3, Quota(now)), now);
            if (stage >= 5) p.Receive(Reply(4, Models), now);
            if (stage >= 6) p.Receive(Reply(5, Thread("fixture-dir")), now);
            return p;
        }
        var p = new WarmupProtocol(QuotaCredentials.Read(auth, key), "fixture-dir");
        var login = p.Receive(Reply(1, new { }), now);
        check(Message(login).GetProperty("method").GetString() == "initialized", "warmup protocol initializes before login");
        var credentialJson = Message(login, 1).GetRawText();
        check(credentialJson.Contains("workspace-a") && credentialJson.Contains("fixture-access") && !credentialJson.Contains("fixture-refresh"), "warmup sends access token only for selected account");
        p.Receive(Reply(2, new { type = "chatgptAuthTokens" }), now);
        check(Message(p.Receive(Reply(3, Quota(now)), now)).GetProperty("method").GetString() == "model/list", "warmup checks fresh server quota before model selection");
        var threadRequest = Message(p.Receive(Reply(4, Models), now)).GetProperty("params");
        check(threadRequest.GetProperty("ephemeral").GetBoolean() && threadRequest.GetProperty("sandbox").GetString() == "read-only" && threadRequest.GetProperty("approvalPolicy").GetString() == "never", "warmup ephemeral read-only no approvals");
        check(!threadRequest.GetProperty("config").GetProperty("features.shell_tool").GetBoolean() && !threadRequest.GetProperty("config").GetProperty("features.apps").GetBoolean() && !threadRequest.GetProperty("config").GetProperty("features.multi_agent").GetBoolean(), "warmup disables shell apps and agents");
        var turn = Message(p.Receive(Reply(5, Thread("fixture-dir")), now)).GetProperty("params");
        check(turn.GetProperty("model").GetString() == WarmupPolicy.Model && turn.GetProperty("effort").GetString() == "low" && turn.GetProperty("input")[0].GetProperty("text").GetString() == "回复ok", "warmup one minimal request on fixed verified model");
        var sandboxPolicy = turn.GetProperty("sandboxPolicy");
        check(!sandboxPolicy.TryGetProperty("access", out _) && !sandboxPolicy.GetProperty("networkAccess").GetBoolean(), "warmup compatible readOnly schema without obsolete access");
        p.Receive(Complete("other-turn"), now); p.Receive(Complete(), now);
        check(Message(p.Receive(Reply(6, new { turn = new { id = "turn-fixture" } }), now)).GetProperty("method").GetString() == "account/rateLimits/read", "warmup completion before response matched by turn ID");
        var result = p.Receive(Reply(7, Quota(now)), now).Result!;
        check(result.Sent && result.Message.Contains("以官方额度为准"), "warmup completion does not claim reset activation or infer percent drop");
        check(p.Receive(Reply(7, Quota(now)), now).Messages.Length == 0, "warmup duplicate completion produces no extra request");
        var blocked = StartTo(3).Receive(Reply(3, Quota(now, week: 100)), now);
        check(blocked.Result?.Sent == false && blocked.Messages.Length == 0, "warmup depleted server recheck sends no turn");
        Reject(() => StartTo(4).Receive(Reply(4, new { data = Array.Empty<object>() }), now), "warmup missing Luna never silently changes model");
        var paging = StartTo(4);
        for (var n = 0; n < 3; n++) check(Message(paging.Receive(Reply(4, new { data = Array.Empty<object>(), nextCursor = "next" }), now)).GetProperty("id").GetInt32() == 4, "warmup bounded model pagination");
        Reject(() => paging.Receive(Reply(4, new { data = Array.Empty<object>(), nextCursor = "next" }), now), "warmup model paging limit");
        foreach (var wrong in new[] { Thread("wrong-dir"), Thread("fixture-dir", ephemeral: false), Thread("fixture-dir", model: "other"), Thread("fixture-dir", sandbox: "dangerFullAccess") })
            Reject(() => StartTo().Receive(Reply(5, wrong), now), "warmup validates session isolation before turn");
        foreach (var method in new[] { "account/chatgptAuthTokens/refresh", "item/commandExecution/requestApproval" })
            Reject(() => StartTo(6).Receive(J(new { id = 42, method, @params = new { } }), now), "warmup rejects token refresh and extra server requests");
        Reject(() => StartTo(6).Receive(J(new { method = "item/started", @params = new { threadId = "thread-fixture", item = new { type = "commandExecution" } } }), now), "warmup aborts unexpected tool item");
        var failed = StartTo(6); failed.Receive(Reply(6, new { turn = new { id = "turn-fixture" } }), now);
        check(failed.Receive(Complete(thread: "unrelated"), now).Messages.Length == 0 && failed.Receive(Complete("unrelated"), now).Messages.Length == 0, "warmup ignores other thread and turn notifications");
        Reject(() => failed.Receive(Complete(status: "failed"), now), "warmup failed turn never reports success");
        try { StartTo(6).Receive(J(new { id = 6, error = new { message = "fixture-secret" } }), now); check(false, "warmup server errors redacted"); }
        catch (UserError ex) { check(!ex.Message.Contains("fixture-secret"), "warmup server errors redacted"); }

        var root = Path.Combine(OperatingSystem.IsMacOS() ? "/private/tmp" : Path.GetTempPath(), "still-warmup-tests-" + Guid.NewGuid());
        Directory.CreateDirectory(root);
        try
        {
            var paths = new Paths(root, Path.Combine(root, "desktop"));
            var vault = new EncryptedVault(Path.Combine(root, "vault"), new FixtureProtector());
            var store = new AccountStore(paths, vault);
            var library = store.Capture(new(), auth); var account = library.Accounts[0];
            check(account.Warmup == null && SafeFiles.Load(paths.Metadata).Accounts[0].Warmup == null, "warmup old metadata upgrade remains off");
            library.Accounts[0] = account = account with { Warmup = enabled }; store.Save(library);
            var other = TestSuite.Fixture("other", "other-workspace"); SafeFiles.Write(paths.Auth, other);
            var authBefore = SafeFiles.Read(paths.Auth); var vaultBefore = File.ReadAllBytes(Path.Combine(root, "vault", account.Id + ".bin"));
            int calls = 0;
            var service = new WarmupService(paths, vault);
            async Task<WarmupResult> Send(byte[] data, string expectedKey, CancellationToken token)
            {
                calls++; await Task.Yield();
                var claim = store.Load().Accounts[0].Warmup!;
                check(claim.Paused && claim.LastAttempt == now, "warmup durable pause before model request");
                check(Identity.Read(data).Key == key && expectedKey == key, "warmup other account never uses live unrelated token");
                Reject(() => { using var held = new OperationLock(root); }, "warmup holds interprocess lock during turn");
                return new(q, true, "预热消息已发送 · 窗口状态以官方额度为准");
            }
            var run = await service.RunAsync(account, q, false, Send, CancellationToken.None, () => now);
            check(run.Result?.Sent == true && run.Library.Accounts[0].Warmup is { Paused: false } r && r.NextAt == now.AddSeconds(18060), "warmup service persists success and schedule");
            await service.RunAsync(account, q, false, Send, CancellationToken.None, () => now);
            check(calls == 1, "warmup durable schedule prevents duplicate app/restart request");
            check(SafeFiles.Same(authBefore, SafeFiles.Read(paths.Auth)) && SafeFiles.Same(vaultBefore, File.ReadAllBytes(Path.Combine(root, "vault", account.Id + ".bin"))), "warmup preserves desktop auth and encrypted vault bytes");
            var captured = store.Capture(store.Load(), TestSuite.Fixture(refresh: "fresh"));
            check(captured.Accounts[0].Warmup?.NextAt == now.AddSeconds(18060), "warmup updating login backup preserves scheduling consent");
            var time = now.AddHours(6); var freshQ = QuotaSnapshot.Parse(J(Quota(time)), time);
            var stopped = await service.RunAsync(account, freshQ, false, (_, _, _) => throw new IOException("fixture-secret"), CancellationToken.None, () => time);
            check(stopped.Library.Accounts[0].Warmup?.Paused == true && !stopped.Notice.Contains("fixture-secret"), "warmup failure persists pause and hides raw details");
            await service.RunAsync(account, freshQ, false, (_, _, _) => { calls++; return Task.FromResult(new WarmupResult(freshQ, true, "fixture")); }, CancellationToken.None, () => time);
            check(calls == 1, "warmup uncertain failure is not automatically retried");
            var metadataBefore = File.ReadAllBytes(paths.Metadata);
            using var cancelled = new CancellationTokenSource(); cancelled.Cancel();
            await RejectAsync(() => service.RunAsync(account, freshQ with { FetchedAt = time.AddMinutes(2) }, true, Send, cancelled.Token, () => time.AddMinutes(2)), "warmup pre-cancel sends no message");
            check(SafeFiles.Same(metadataBefore, File.ReadAllBytes(paths.Metadata)), "warmup pre-cancel preserves metadata");
            var newNow = time.AddMinutes(2); freshQ = QuotaSnapshot.Parse(J(Quota(newNow)), newNow);
            var retry = await service.RunAsync(account, freshQ, true, (_, _, _) => Task.FromResult(new WarmupResult(freshQ, true, "预热消息已发送")), CancellationToken.None, () => newNow);
            check(retry.Library.Accounts[0].Warmup?.Paused == false, "warmup explicit manual retry resumes enabled schedule");
            // Simulate read-only metadata disk: no request may occur until the claim is durable.
            int beforeFailure = calls;
            var failingStore = new WarmupService(paths, vault, (_, _) => throw new IOException("fixture save failure"));
            var later = newNow.AddHours(6); var laterQ = QuotaSnapshot.Parse(J(Quota(later)), later);
            await RejectAsync(() => failingStore.RunAsync(account, laterQ, true, Send, CancellationToken.None, () => later), "warmup claim write failure stops before turn");
            check(calls == beforeFailure, "warmup no request on failed claim persistence");
            int saves = 0;
            var finalSaveFails = new WarmupService(paths, vault, (_, _) => { if (++saves == 2) throw new IOException("fixture final save failure"); });
            await RejectAsync(() => finalSaveFails.RunAsync(account, laterQ, true, (_, _, _) => Task.FromResult(new WarmupResult(laterQ, true, "sent")), CancellationToken.None, () => later), "warmup final save failure reported after completed request");
            check(store.Load().Accounts[0].Warmup?.Paused == true, "warmup final save failure leaves durable pause for restart");
            var newest = System.Text.Encoding.UTF8.GetBytes(System.Text.Encoding.UTF8.GetString(auth).Replace("fixture-access", "fresh-access"));
            SafeFiles.Write(paths.Auth, newest);
            var nextTime = later.AddMinutes(2); var nextQ = QuotaSnapshot.Parse(J(Quota(nextTime)), nextTime);
            bool usedLive = false;
            await service.RunAsync(account, nextQ, true, (data, _, _) => { usedLive = data.SequenceEqual(newest); return Task.FromResult(new WarmupResult(nextQ, true, "sent")); }, CancellationToken.None, () => nextTime);
            check(usedLive && SafeFiles.Same(newest, SafeFiles.Read(paths.Auth)), "warmup matching account uses newest live access token without writing it");
            var off = store.Load(); off.Accounts[0] = off.Accounts[0] with { Warmup = new() }; store.Save(off);
            var manualOff = await service.RunAsync(account, nextQ, true, (_, _, _) => Task.FromResult(new WarmupResult(nextQ, true, "sent")), CancellationToken.None, () => nextTime);
            check(manualOff.Result?.Sent == true && manualOff.Library.Accounts[0].Warmup?.Enabled == false, "warmup manual request does not enable automatic scheduling");
            var reset = store.Load(); reset.Accounts[0] = reset.Accounts[0] with { Warmup = enabled }; store.Save(reset);
            var skip = await service.RunAsync(account, nextQ, false, (_, _, _) => Task.FromResult(new WarmupResult(nextQ, false, "额度状态变化")), CancellationToken.None, () => nextTime);
            check(skip.Library.Accounts[0].Warmup is { LastAttempt: null, Paused: false }, "warmup server quota rejection restores previous schedule without fake attempt");
            await RejectAsync(() => service.RunAsync(account with { IdentityKey = "wrong" }, nextQ, true, Send, CancellationToken.None, () => nextTime), "warmup stale or replaced identity blocks request");
            var broker = new WarmupBroker("missing-cli", root);
            await RejectAsync(() => broker.RunAsync(auth, key, CancellationToken.None), "warmup launch failure reported");
            check(!Directory.EnumerateDirectories(Path.Combine(root, "warmup-requests")).Any(), "warmup launch failure cleans isolated directory");
            FakeTransport? transport = null;
            var transportResult = await broker.RunAsync(auth, key, CancellationToken.None, dir => transport = new FakeTransport(dir));
            check(transportResult.Sent && transport!.Sent.Count(x => x.GetProperty("method").GetString() == "turn/start") == 1, "warmup full broker exchange sends exactly one turn");
            check(transport!.Disposed && !Directory.Exists(transport.Dir), "warmup child disposed before isolated directory cleanup");
            check(!transport.Sent.Any(x => x.GetRawText().Contains("fixture-refresh")) && !Directory.EnumerateFiles(Path.Combine(root, "warmup-requests"), "auth.json", SearchOption.AllDirectories).Any(), "warmup transport never sends refresh token or writes auth");
            FakeTransport? hanging = null;
            await RejectAsync(() => broker.RunAsync(auth, key, CancellationToken.None, dir => hanging = new FakeTransport(dir) { Hang = true }, TimeSpan.FromMilliseconds(30)), "warmup deadline stops stalled protocol");
            check(hanging?.Disposed == true && !Directory.Exists(hanging.Dir), "warmup timeout disposes and cleans up");
        }
        finally { Directory.Delete(root, true); }
    }
    sealed class FakeTransport(string dir) : IWarmupTransport
    {
        public string Dir => dir;
        public bool Disposed, Hang;
        public List<JsonElement> Sent = [];
        readonly Queue<JsonElement> replies = [];
        public Task SendAsync(object message, CancellationToken cancellation)
        {
            cancellation.ThrowIfCancellationRequested(); var frame = J(message); Sent.Add(frame);
            if (!frame.TryGetProperty("id", out var id)) return Task.CompletedTask;
            var n = id.GetInt32();
            object result = n switch { 2 => new { type = "chatgptAuthTokens" }, 3 or 7 => Quota(DateTimeOffset.UtcNow), 4 => Models, 5 => Thread(dir), 6 => new { turn = new { id = "turn-fixture" } }, _ => new { } };
            replies.Enqueue(Reply(n, result));
            if (n == 6) replies.Enqueue(Complete());
            return Task.CompletedTask;
        }
        public async Task<JsonElement> ReadAsync(CancellationToken cancellation)
        {
            if (Hang) await Task.Delay(Timeout.Infinite, cancellation);
            cancellation.ThrowIfCancellationRequested(); return replies.Dequeue();
        }
        public ValueTask DisposeAsync() { Disposed = true; return ValueTask.CompletedTask; }
    }
}
