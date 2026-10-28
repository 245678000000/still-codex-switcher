using System.IO;
using System.Text.Json;
using Still.Core;
namespace Still.Tests;
public static class ResetCreditTests
{
    static JsonElement Json(string text) { using var d = JsonDocument.Parse(text); return d.RootElement.Clone(); }
    public static async Task Run(Action<bool, string> check)
    {
        var now = DateTimeOffset.FromUnixTimeSeconds(1900000000);
        var q = QuotaSnapshot.Parse(Json("""{"rateLimitResetCredits":{"availableCount":3,"credits":[{"id":"fixture-card","resetType":"codexRateLimits","status":"available","expiresAt":1900086400}]}}"""), now);
        check(q.ResetCredits?.AvailableCount == 3, "reset count uses server total, not capped detail count");
        check(q.ResetCredits?.Credits?[0].ExpiresAt == now.AddDays(1), "reset expiry Unix seconds");
        check(q.ResetCredits?.ExpiryLabel(now).Contains("已知") == true, "reset capped expiry details labelled");
        var state = new QuotaState(q);
        check(ResetAttempt.Prepare(null, state, false, now) == null, "reset cancel creates no request");
        var attempt = ResetAttempt.Prepare(null, state, true, now)!;
        var saved = JsonSerializer.Deserialize<ResetAttempt>(JsonSerializer.Serialize(attempt));
        check(ResetAttempt.Prepare(saved, new(), true, now) == attempt, "reset restart retry preserves durable key and card");
        var auth = TestSuite.Fixture(); var credentials = QuotaCredentials.Read(auth, Identity.Read(auth).Key);
        var rpc = new FixtureRpc("alreadyRedeemed");
        var result = await ResetProtocol.ConsumeAsync(rpc, credentials, attempt, CancellationToken.None);
        check(result == ResetOutcome.AlreadyRedeemed, "reset duplicate outcome not a second success");
        check(rpc.Calls.Select(c => c.Method).SequenceEqual(new[] { "initialize", "initialized", "account/login/start", "account/rateLimitResetCredit/consume" }), "reset exactly one consume, no model or paid purchase call");
        var parameters = rpc.Calls.Last().Params;
        check(parameters.GetProperty("idempotencyKey").GetString() == attempt.IdempotencyKey && parameters.GetProperty("creditId").GetString() == "fixture-card", "reset consumes selected credit with stable key");
        check(!rpc.Calls[2].Params.GetRawText().Contains("fixture-refresh"), "reset passes no refresh token");
        foreach (var invalid in new[] { "-1", "1.5", "true", "\"2\"", "null" })
            check(QuotaSnapshot.Parse(Json("{\"rateLimitResetCredits\":{\"availableCount\":" + invalid + "}}"), now).ResetCredits == null, "reset malformed count remains unknown");
        check(QuotaSnapshot.Parse(Json("{}"), now).ResetCredits == null, "reset unsupported data not zero balance");
        check(!ResetCredits.CanStart(state, now.AddMinutes(5)) && !ResetCredits.CanStart(state, now.AddSeconds(-1)) && !ResetCredits.CanStart(state with { Error = "offline" }, now), "reset stale and failed refresh block new use");
        bool staleReset = false;
        try { ResetAttempt.Prepare(null, state, true, now, lastResetAt: now); } catch (UserError) { staleReset = true; }
        check(staleReset, "reset cross-instance stale snapshot blocked after earlier redemption");
        var expired = QuotaSnapshot.Parse(Json("""{"rateLimitResetCredits":{"availableCount":1,"credits":[{"id":"expired","status":"available","resetType":"codexRateLimits","expiresAt":1899999999}]}}"""), now);
        check(!ResetCredits.CanStart(new(expired), now), "reset expired card waits for fresh data");
        foreach (var (raw, text) in new[] { ("null", "无到期限制"), ("\"invalid\"", "部分有效期待确认") })
        {
            var cards = QuotaSnapshot.Parse(Json("{\"rateLimitResetCredits\":{\"availableCount\":1,\"credits\":[{\"id\":\"card\",\"status\":\"available\",\"resetType\":\"codexRateLimits\",\"expiresAt\":" + raw + "}]}}"), now).ResetCredits;
            check(cards?.ExpiryLabel(now) == text, "reset null expiry distinct from malformed expiry");
        }
        foreach (var (value, expected) in new[] { ("reset", ResetOutcome.Reset), ("noCredit", ResetOutcome.NoCredit), ("nothingToReset", ResetOutcome.NothingToReset) })
            check(await ResetProtocol.ConsumeAsync(new FixtureRpc(value), credentials, attempt, CancellationToken.None) == expected, "reset backend outcome: " + value);
        bool unknown = false;
        try { await ResetProtocol.ConsumeAsync(new FixtureRpc("futureOutcome"), credentials, attempt, CancellationToken.None); } catch (UserError) { unknown = true; }
        check(unknown, "reset unknown outcome stays pending, not success");
        var root = Path.Combine(OperatingSystem.IsMacOS() ? "/private/tmp" : Path.GetTempPath(), "still-reset-storage-" + Guid.NewGuid());
        try
        {
            var paths = new Paths(root, Path.Combine(root, "live-fixture")); var vault = new MemoryVault(); var store = new AccountStore(paths, vault);
            var lib = store.Capture(new Library(), auth);
            lib.Accounts[0] = lib.Accounts[0] with { ResetAttempt = attempt }; store.Save(lib);
            lib = store.Capture(store.Load(), auth);
            check(store.Load().Accounts[0].ResetAttempt == attempt, "reset updated login preserves persisted attempt");
            bool blocked = false; try { store.Remove(lib, lib.Accounts[0].Id); } catch (UserError) { blocked = true; }
            check(blocked && store.Load().Accounts[0].ResetAttempt == attempt, "reset pending attempt preserved when removal requested");
        }
        finally { if (Directory.Exists(root)) Directory.Delete(root, true); }
    }
    sealed class FixtureRpc(string outcome) : IQuotaRpc
    {
        public readonly List<(string Method, JsonElement Params)> Calls = [];
        public Task<JsonElement> CallAsync(string method, object? parameters, CancellationToken cancel)
        {
            cancel.ThrowIfCancellationRequested(); Calls.Add((method, JsonSerializer.SerializeToElement(parameters)));
            return Task.FromResult(method == "account/login/start" ? Json("""{"type":"chatgptAuthTokens"}""") :
                method == "account/rateLimitResetCredit/consume" ? JsonSerializer.SerializeToElement(new { outcome }) : Json("{}"));
        }
        public Task NotifyAsync(string method, CancellationToken cancel) { cancel.ThrowIfCancellationRequested(); Calls.Add((method, default)); return Task.CompletedTask; }
    }
}
