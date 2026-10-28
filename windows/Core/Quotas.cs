using System.Globalization;
using System.Text.Json;

namespace Still.Core;

public sealed record QuotaWindow(double RemainingPercent, DateTimeOffset? ResetsAt);
public sealed record QuotaSnapshot(QuotaWindow? FiveHours, QuotaWindow? SevenDays, DateTimeOffset FetchedAt, ResetCredits? ResetCredits = null)
{
    public static QuotaSnapshot Parse(JsonElement result, DateTimeOffset now)
    {
        // Prefer the explicit Codex bucket. Never present another model's limit as Codex's.
        JsonElement bucket = default;
        if (result.ValueKind != JsonValueKind.Object) throw new UserError("额度响应格式异常，请稍后重试。");
        if (result.TryGetProperty("rateLimitsByLimitId", out var map) && map.ValueKind != JsonValueKind.Null)
        {
            if (map.ValueKind != JsonValueKind.Object) throw new UserError("额度响应格式异常，请稍后重试。");
            map.TryGetProperty("codex", out bucket);
        }
        else if (result.TryGetProperty("rateLimits", out var legacy)) bucket = legacy;
        var cards = Still.Core.ResetCredits.Parse(result);
        if (bucket.ValueKind != JsonValueKind.Object) return new(null, null, now, cards);
        if (bucket.TryGetProperty("limitId", out var id) && id.ValueKind == JsonValueKind.String && id.GetString() != "codex")
            return new(null, null, now, cards);
        QuotaWindow? Read(int duration)
        {
            var matches = new List<JsonElement>();
            foreach (var name in new[] { "primary", "secondary" })
                if (bucket.TryGetProperty(name, out var w) && w.ValueKind == JsonValueKind.Object &&
                    w.TryGetProperty("windowDurationMins", out var d) && d.ValueKind == JsonValueKind.Number && d.TryGetInt32(out var mins) && mins == duration)
                    matches.Add(w);
            // Missing/ambiguous windows are unknown, not full quota. Positions are not durations.
            if (matches.Count != 1) return null;
            var window = matches[0];
            if (!window.TryGetProperty("usedPercent", out var p) || p.ValueKind != JsonValueKind.Number || !p.TryGetDouble(out var used) || !double.IsFinite(used)) return null;
            DateTimeOffset? reset = null;
            if (window.TryGetProperty("resetsAt", out var r) && r.ValueKind == JsonValueKind.Number && r.TryGetInt64(out var seconds))
                try { reset = DateTimeOffset.FromUnixTimeSeconds(seconds); } catch (ArgumentOutOfRangeException) { }
            return new(Math.Clamp(100 - used, 0, 100), reset);
        }
        return new(Read(300), Read(10080), now, cards);
    }
}

// Memory-only state, indexed by saved account ID. Never written to accounts.json or a log.
public sealed record QuotaState(QuotaSnapshot? Snapshot = null, string? Error = null, bool Loading = false, DateTimeOffset? AttemptedAt = null)
{
    public bool IsStale(DateTimeOffset now) => Snapshot != null &&
        (Error != null || now - Snapshot.FetchedAt >= TimeSpan.FromMinutes(5) || now < Snapshot.FetchedAt ||
         Snapshot.FiveHours?.ResetsAt <= now || Snapshot.SevenDays?.ResetsAt <= now);
    public string Status(DateTimeOffset now)
    {
        var time = Snapshot == null ? "" : " · " + Snapshot.FetchedAt.ToLocalTime().ToString("HH:mm");
        if (Loading) return "正在刷新…" + (Snapshot == null ? "" : " · 上次结果" + time);
        if (Error != null) return Error + (Snapshot == null ? "" : " · 上次结果" + time);
        if (Snapshot == null) return "待刷新";
        return (IsStale(now) ? "上次结果 · 待刷新" : "已刷新") + time;
    }
    public static string Percent(QuotaWindow? w) => w == null ? "—" : w.RemainingPercent.ToString("0.#", CultureInfo.InvariantCulture) + "%";
    public static string Reset(QuotaWindow? w, DateTimeOffset now)
    {
        if (w == null) return "暂未提供数据";
        if (w.ResetsAt is not { } reset) return "未提供重置时间";
        return reset <= now ? "已到重置时间 · 待刷新" : reset.ToLocalTime().ToString("MM-dd HH:mm") + " 重置";
    }
}

public sealed class QuotaCredentials
{
    // Avoid record-generated ToString: access tokens must never appear in diagnostics.
    public string AccessToken { get; }
    public string AccountId { get; }
    public string Plan { get; }
    QuotaCredentials(string accessToken, string accountId, string plan) => (AccessToken, AccountId, Plan) = (accessToken, accountId, plan);
    public static QuotaCredentials Read(byte[] auth, string expectedKey)
    {
        var identity = Identity.Read(auth);
        if (identity.Key != expectedKey) throw new UserError("账号与保存的登录资料不一致，请重新添加。");
        using var doc = JsonDocument.Parse(auth); var tokens = doc.RootElement.GetProperty("tokens");
        string? account = tokens.TryGetProperty("account_id", out var a) && a.ValueKind == JsonValueKind.String ? a.GetString() : null;
        if (string.IsNullOrWhiteSpace(account))
        {
            var payload = tokens.GetProperty("id_token").GetString()!.Split('.')[1].Replace('-', '+').Replace('_', '/');
            using var claims = JsonDocument.Parse(Convert.FromBase64String(payload.PadRight((payload.Length + 3) / 4 * 4, '=')));
            account = claims.RootElement.GetProperty("https://api.openai.com/auth").GetProperty("chatgpt_account_id").GetString();
        }
        if (string.IsNullOrWhiteSpace(account)) throw new UserError("缺少账号工作区信息，请重新添加。");
        return new(tokens.GetProperty("access_token").GetString()!, account, identity.Plan);
    }
    public override string ToString() => "QuotaCredentials [redacted]";
}

public interface IQuotaRpc
{
    Task<JsonElement> CallAsync(string method, object? parameters, CancellationToken cancellation);
    Task NotifyAsync(string method, CancellationToken cancellation);
}
public static class QuotaProtocol
{
    public static async Task<QuotaSnapshot> ReadAsync(IQuotaRpc rpc, QuotaCredentials credentials, CancellationToken cancellation)
    {
        await rpc.CallAsync("initialize", new { clientInfo = new { name = "still_codex_switcher_windows", title = "Still quota viewer", version = "1.1.0" }, capabilities = new { experimentalApi = true } }, cancellation);
        await rpc.NotifyAsync("initialized", cancellation);
        // External token mode uses only the access token in this isolated child. No refresh token
        // is supplied, so viewing quotas cannot rotate a desktop/CLI session's refresh token.
        var login = await rpc.CallAsync("account/login/start", new { type = "chatgptAuthTokens", accessToken = credentials.AccessToken, chatgptAccountId = credentials.AccountId, chatgptPlanType = credentials.Plan }, cancellation);
        if (!login.TryGetProperty("type", out var type) || type.GetString() != "chatgptAuthTokens")
            throw new UserError("当前 CLI 的额度查询协议不兼容，请更新官方 Codex。");
        var result = await rpc.CallAsync("account/rateLimits/read", null, cancellation);
        return QuotaSnapshot.Parse(result, DateTimeOffset.UtcNow);
    }
}
