using System.Text.Json;
using System.IO;
using Still.Core;

namespace Still.Tests;
public static class QuotaTests
{
    static JsonElement Json(string value) { using var doc = JsonDocument.Parse(value); return doc.RootElement.Clone(); }
    public static async Task Run(Action<bool, string> check)
    {
        var now = DateTimeOffset.FromUnixTimeSeconds(1900000000);
        QuotaSnapshot Parse(string value) => QuotaSnapshot.Parse(Json(value), now);
        const string windows = "\"primary\":{\"usedPercent\":24.5,\"windowDurationMins\":300,\"resetsAt\":1900003600},\"secondary\":{\"usedPercent\":80,\"windowDurationMins\":10080,\"resetsAt\":1900400000}";
        var normal = Parse("{\"rateLimits\":{\"limitId\":\"codex\"," + windows + "}}");
        check(normal.FiveHours?.RemainingPercent == 75.5 && normal.SevenDays?.RemainingPercent == 20, "quota remaining, not used percentage");
        check(normal.FiveHours?.ResetsAt == now.AddHours(1), "quota Unix seconds conversion");
        check(normal.FetchedAt == now, "quota fetch timestamp");
        var preferred = Parse("{\"rateLimitsByLimitId\":{\"codex\":{" + windows + "}},\"rateLimits\":{\"primary\":{\"usedPercent\":99,\"windowDurationMins\":300}}}");
        check(preferred.FiveHours?.RemainingPercent == 75.5, "quota codex map preferred over legacy");
        foreach (var response in new[] { "{}", "{\"rateLimits\":null}", "{\"rateLimitsByLimitId\":{\"other\":{" + windows + "}},\"rateLimits\":{" + windows + "}}", "{\"rateLimitsByLimitId\":{},\"rateLimits\":{" + windows + "}}", "{\"rateLimits\":{\"limitId\":\"other\"," + windows + "}}" })
        {
            var q = Parse(response); check(q.FiveHours == null && q.SevenDays == null, "quota absent or other bucket remains unknown");
        }
        check(Parse("{\"rateLimitsByLimitId\":null,\"rateLimits\":{" + windows + "}}").FiveHours != null, "quota null map uses legacy");
        var swapped = Parse("{\"rateLimits\":{\"primary\":{\"usedPercent\":30,\"windowDurationMins\":10080},\"secondary\":{\"usedPercent\":60,\"windowDurationMins\":300}}}");
        check(swapped.FiveHours?.RemainingPercent == 40 && swapped.SevenDays?.RemainingPercent == 70, "quota maps by duration, not position");
        foreach (var w in new[] { "null", "{}", "{\"usedPercent\":0}", "{\"usedPercent\":null,\"windowDurationMins\":300}", "{\"usedPercent\":\"20\",\"windowDurationMins\":300}", "{\"usedPercent\":0,\"windowDurationMins\":60}", "{\"usedPercent\":1e999,\"windowDurationMins\":300}" })
            check(Parse("{\"rateLimits\":{\"primary\":" + w + "}}").FiveHours == null, "quota missing or invalid window not treated as full");
        check(Parse("{\"rateLimits\":{\"primary\":{\"usedPercent\":120,\"windowDurationMins\":300}}}").FiveHours?.RemainingPercent == 0, "quota upper usage clamped");
        check(Parse("{\"rateLimits\":{\"primary\":{\"usedPercent\":-5,\"windowDurationMins\":300}}}").FiveHours?.RemainingPercent == 100, "quota lower usage clamped");
        check(Parse("{\"rateLimits\":{\"primary\":{\"usedPercent\":1,\"windowDurationMins\":300,\"resetsAt\":9223372036854775807}}}").FiveHours?.ResetsAt == null, "quota invalid timestamp stays unknown");
        check(Parse("{\"rateLimits\":{\"primary\":{\"usedPercent\":1,\"windowDurationMins\":300},\"secondary\":{\"usedPercent\":2,\"windowDurationMins\":300}}}").FiveHours == null, "quota ambiguous same-duration windows stay unknown");
        var state = new QuotaState(normal);
        check(!state.IsStale(now) && state.IsStale(now.AddMinutes(5)), "quota stale after five minutes");
        check(state.IsStale(now.AddMinutes(-1)), "quota clock rollback marked stale");
        check((state with { Error = "fixture error" }).IsStale(now), "quota failed refresh retains stale snapshot");
        check((state with { Loading = true }).Status(now).Contains("正在刷新"), "quota loading state");
        check(new QuotaState().Status(now) == "待刷新" && QuotaState.Percent(null) == "—", "quota initial state not zero or full");
        check(QuotaState.Percent(normal.FiveHours) == "75.5%", "quota percentage presentation");
        var expired = new QuotaSnapshot(new(12, now.AddMinutes(-1)), null, now);
        check(new QuotaState(expired).IsStale(now) && QuotaState.Reset(expired.FiveHours, now).Contains("待刷新") && expired.FiveHours!.RemainingPercent == 12, "quota reset crossing never invents full quota");
        check(QuotaState.Reset(new(0, null), now).Contains("未提供") && QuotaState.Reset(null, now).Contains("暂未提供"), "quota missing time and missing window distinguished");
        var a = TestSuite.Fixture(); var key = Identity.Read(a).Key;
        var credentials = QuotaCredentials.Read(a, key);
        check(credentials.AccountId == "workspace-a" && credentials.AccessToken == "fixture-access", "quota credentials workspace isolation");
        check(!credentials.ToString().Contains("fixture-access"), "quota credentials redacted in diagnostics");
        bool rejected = false; try { QuotaCredentials.Read(a, "wrong-account"); } catch (UserError) { rejected = true; }
        check(rejected, "quota wrong account credentials rejected");
        var rpc = new FixtureRpc(Json("{\"rateLimits\":{" + windows + "}}"));
        var result = await QuotaProtocol.ReadAsync(rpc, credentials, CancellationToken.None);
        check(rpc.Calls.Select(c => c.Method).SequenceEqual(new[] { "initialize", "initialized", "account/login/start", "account/rateLimits/read" }), "quota RPC sequence is read-only after ephemeral login");
        check(rpc.Calls[0].Params!.Value.GetProperty("capabilities").GetProperty("experimentalApi").GetBoolean(), "quota experimental capability negotiated");
        var login = rpc.Calls[2].Params!.Value;
        check(login.GetProperty("chatgptAccountId").GetString() == "workspace-a" && login.GetProperty("accessToken").GetString() == "fixture-access", "quota RPC uses selected account");
        check(!login.TryGetProperty("refresh_token", out _) && !login.GetRawText().Contains("fixture-refresh"), "quota RPC never sends refresh token");
        check(result.FiveHours?.RemainingPercent == 75.5, "quota protocol returns parsed snapshot");
        var rpc2 = new FixtureRpc(Json("{\"rateLimits\":{\"primary\":{\"usedPercent\":90,\"windowDurationMins\":300}}}"));
        var b = TestSuite.Fixture("fixture-b", "workspace-b");
        var other = await QuotaProtocol.ReadAsync(rpc2, QuotaCredentials.Read(b, Identity.Read(b).Key), CancellationToken.None);
        check(other.FiveHours?.RemainingPercent == 10 && result.FiveHours?.RemainingPercent == 75.5 && rpc2.Calls[2].Params!.Value.GetProperty("chatgptAccountId").GetString() == "workspace-b", "quota accounts never share results or credentials");
        using var cancel = new CancellationTokenSource(); cancel.Cancel();
        rejected = false; try { await QuotaProtocol.ReadAsync(new FixtureRpc(Json("{}")), credentials, cancel.Token); } catch (OperationCanceledException) { rejected = true; }
        check(rejected, "quota cancellation propagates");
        rejected = false; try { await QuotaProtocol.ReadAsync(new FixtureRpc(Json("{}")) { LoginType = "chatgpt" }, credentials, CancellationToken.None); } catch (UserError) { rejected = true; }
        check(rejected, "quota incompatible login protocol rejected");
        var path = Path.Combine(OperatingSystem.IsMacOS() ? "/private/tmp" : Path.GetTempPath(), "still-quota-failure-" + Guid.NewGuid());
        try
        {
            rejected = false; try { await new QuotaBroker(Path.Combine(path, "missing-cli"), path).ReadAsync(a, key, CancellationToken.None); } catch { rejected = true; }
            check(rejected && !Directory.EnumerateDirectories(Path.Combine(path, "quota-queries")).Any(), "quota child launch failure cleans private home");
            check(!Directory.EnumerateFiles(path, "auth.json", SearchOption.AllDirectories).Any(), "quota never writes credentials to disk");
        }
        finally { if (Directory.Exists(path)) Directory.Delete(path, true); }
    }
    sealed class FixtureRpc(JsonElement response) : IQuotaRpc
    {
        public string LoginType = "chatgptAuthTokens";
        public readonly List<(string Method, JsonElement? Params)> Calls = [];
        public Task<JsonElement> CallAsync(string method, object? parameters, CancellationToken cancellation)
        {
            cancellation.ThrowIfCancellationRequested(); Calls.Add((method, JsonSerializer.SerializeToElement(parameters)));
            return Task.FromResult(method == "account/login/start" ? JsonSerializer.SerializeToElement(new { type = LoginType }) : method == "account/rateLimits/read" ? response : Json("{}"));
        }
        public Task NotifyAsync(string method, CancellationToken cancellation) { cancellation.ThrowIfCancellationRequested(); Calls.Add((method, null)); return Task.CompletedTask; }
    }
}
