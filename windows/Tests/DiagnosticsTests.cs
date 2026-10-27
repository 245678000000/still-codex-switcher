using System.Text.Json;
using System.IO;
using Still.Core;
namespace Still.Tests;
public static class DiagnosticsTests
{
    static JsonElement Json(string value) { using var doc = JsonDocument.Parse(value); return doc.RootElement.Clone(); }
    public static async Task Run(Action<bool, string> check)
    {
        var launch = DiagnosticBroker.CreateStartInfo("fixture-cli", "/fixture/home");
        check(launch.Environment["HOME"] == "/fixture/home" && launch.Environment["CODEX_SQLITE_HOME"] == Path.Combine("/fixture/home", "state") && !launch.Environment.ContainsKey("OPENAI_API_KEY"), "diagnostics child home and database isolated from desktop");
        var now = DateTimeOffset.FromUnixTimeSeconds(1900000000);
        var missing = DiagnosticReport.FromQuota(new(null, null, now));
        check(missing.Checks.Single(x => x.Id == "quota").Level == DiagnosticLevel.Unknown, "diagnostics missing windows remain unknown, not full or healthy");
        var used = DiagnosticReport.FromQuota(new(new(0, now.AddHours(1)), new(20, now.AddDays(1)), now));
        check(used.Checks[0].Level == DiagnosticLevel.Attention && used.Summary == "有项目需要处理", "diagnostics exhausted window requests attention");
        check(!used.IsStale(now) && used.IsStale(now.AddMinutes(5)) && used.IsStale(now.AddMinutes(-1)), "diagnostics result is timestamped and expires");
        var auth = TestSuite.Fixture(); var key = Identity.Read(auth).Key;
        var credentials = QuotaCredentials.Read(auth, key);
        DiagnosticProtocol Begin()
        {
            var p = new DiagnosticProtocol(credentials);
            var login = p.Receive(Json("{\"id\":1,\"result\":{}}"), now);
            var serialized = JsonSerializer.Serialize(login);
            check(serialized.Contains("workspace-a") && !serialized.Contains("fixture-refresh"), "diagnostics selected identity and access token only");
            p.Receive(Json("{\"id\":2,\"result\":{\"type\":\"chatgptAuthTokens\"}}"), now);
            check(p.Result == null, "diagnostics local token load never reports server health");
            return p;
        }
        var state = Begin();
        state.Receive(Json("{\"id\":3,\"result\":{\"rateLimits\":{\"primary\":{\"usedPercent\":20,\"windowDurationMins\":300},\"secondary\":{\"usedPercent\":50,\"windowDurationMins\":10080}}}}"), now);
        var more = state.Receive(Json("{\"id\":4,\"result\":{\"data\":[{\"model\":\"example-a\"},{\"model\":\"example-hidden\",\"hidden\":true}],\"nextCursor\":\"page-2\"}}"), now);
        check(more.Count == 1 && state.Result == null, "diagnostics paginated catalog read before final result");
        state.Receive(Json("{\"id\":4,\"result\":{\"data\":[{\"model\":\"example-b\"},{\"model\":\"example-a\"}],\"nextCursor\":null}}"), now);
        var result = state.Result!;
        check(result.Models!.SequenceEqual(new[] { "example-a", "example-b" }) && result.Quota?.FiveHours?.RemainingPercent == 80, "diagnostics deduplicates catalog and preserves quota");
        check(result.Checks.Single(x => x.Id == "models").Detail.Contains("尚未验证实际推理"), "diagnostics catalog is not model execution proof");
        check(!JsonSerializer.Serialize(result).Contains("fixture-access"), "diagnostics reports contain no credential");
        foreach (var code in new[] { 401, 403, 429, -32601, -1 })
        {
            var failed = Begin();
            failed.Receive(Json($"{{\"id\":3,\"error\":{{\"code\":{code},\"message\":\"SECRET-server-payload\"}}}}"), now);
            failed.Receive(Json("{\"id\":4,\"result\":{\"data\":[]}}"), now);
            check(failed.Result!.Checks.Any(x => x.Level == DiagnosticLevel.Attention) && !JsonSerializer.Serialize(failed.Result).Contains("SECRET"), "diagnostics service failure redacted and never healthy");
        }
        var refresh = Begin(); refresh.Receive(Json("{\"id\":90,\"method\":\"account/chatgptAuthTokens/refresh\"}"), now);
        check(refresh.Result!.Summary == "有项目需要处理", "diagnostics refresh request stops, no refresh token sent");
        var repeated = Begin(); repeated.Receive(Json("{\"id\":3,\"result\":{}}"), now);
        var page = Json("{\"id\":4,\"result\":{\"data\":[{\"model\":\"example\"}],\"nextCursor\":\"same\"}}");
        repeated.Receive(page, now); repeated.Receive(page, now);
        check(repeated.Result!.Checks.Single(x => x.Id == "models").Level == DiagnosticLevel.Unknown, "diagnostics repeating cursor stops with partial label");
        var root = Path.Combine(OperatingSystem.IsMacOS() ? "/private/tmp" : Path.GetTempPath(), "still-diagnostics-test-" + Guid.NewGuid());
        try
        {
            var broker = new DiagnosticBroker("unused", root);
            var fixture = new ReadFixture();
            var run = await broker.RunAsync(auth, key, CancellationToken.None, _ => fixture);
            check(run.Models?.Single() == "example-a" && fixture.Disposed && fixture.ReadOnly, "diagnostics broker completes only read methods and disposes isolated child");
            using var cancelled = new CancellationTokenSource(); cancelled.Cancel(); var started = false;
            var stop = await broker.RunAsync(auth, key, cancelled.Token, _ => { started = true; return new ReadFixture(); });
            check(!started && stop.Checks[0].Detail.Contains("已取消"), "diagnostics cancelled before start sends no request");
            using var during = new CancellationTokenSource();
            var hanging = new ReadFixture(true) { Reading = () => during.Cancel() };
            var stopped = await broker.RunAsync(auth, key, during.Token, _ => hanging);
            check(stopped.Checks[0].Detail.Contains("已取消") && hanging.Disposed, "diagnostics in-flight cancellation cleans owned child");
            var timeout = new ReadFixture(true); var timeoutStarted = false;
            var timed = await broker.RunAsync(auth, key, CancellationToken.None, _ => { timeoutStarted = true; return timeout; }, TimeSpan.FromMilliseconds(100));
            check(timed.Checks[0].Detail.Contains("超时") && (!timeoutStarted || timeout.Disposed), "diagnostics timeout distinct from user cancellation");
            check(!Directory.EnumerateDirectories(Path.Combine(root, "diagnostic-queries")).Any(), "diagnostics UUID directories removed after all exits");
        }
        finally { if (Directory.Exists(root)) Directory.Delete(root, true); }
    }
    sealed class ReadFixture(bool hang = false) : IWarmupTransport
    {
        readonly Queue<JsonElement> replies = new();
        public bool ReadOnly = true, Disposed;
        public Action? Reading;
        public Task SendAsync(object message, CancellationToken cancellation)
        {
            var value = JsonSerializer.SerializeToElement(message); var method = value.GetProperty("method").GetString();
            if (!new[] { "initialize", "initialized", "account/login/start", "account/rateLimits/read", "model/list" }.Contains(method)) { ReadOnly = false; throw new Exception("unexpected request"); }
            if (!value.TryGetProperty("id", out var id)) return Task.CompletedTask;
            var result = method == "account/login/start" ? "{\"type\":\"chatgptAuthTokens\"}" : method == "model/list" ? "{\"data\":[{\"model\":\"example-a\"}]}" : "{}";
            replies.Enqueue(Json($"{{\"id\":{id.GetInt32()},\"result\":{result}}}")); return Task.CompletedTask;
        }
        public async Task<JsonElement> ReadAsync(CancellationToken cancellation)
        { Reading?.Invoke(); if (hang) await Task.Delay(Timeout.InfiniteTimeSpan, cancellation); return replies.Dequeue(); }
        public ValueTask DisposeAsync() { Disposed = true; return ValueTask.CompletedTask; }
    }
}
