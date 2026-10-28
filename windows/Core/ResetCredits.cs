using System.Text.Json;
namespace Still.Core;

public sealed record ResetCredit(string Id, string ResetType, string Status, DateTimeOffset? ExpiresAt, bool ExpiryKnown)
{
    public bool Usable(DateTimeOffset now) => Status == "available" && ResetType == "codexRateLimits" && ExpiryKnown && (ExpiresAt == null || ExpiresAt > now);
}
public sealed record ResetCredits(int AvailableCount, IReadOnlyList<ResetCredit>? Credits)
{
    public static ResetCredits? Parse(JsonElement result)
    {
        if (!result.TryGetProperty("rateLimitResetCredits", out var obj) || obj.ValueKind != JsonValueKind.Object ||
            !obj.TryGetProperty("availableCount", out var n) || n.ValueKind != JsonValueKind.Number || !n.TryGetInt32(out var count) || count is < 0 or > 1_000_000) return null;
        List<ResetCredit>? rows = null;
        if (obj.TryGetProperty("credits", out var data) && data.ValueKind == JsonValueKind.Array && data.GetArrayLength() <= 10_000)
        {
            rows = []; var ids = new HashSet<string>();
            foreach (var row in data.EnumerateArray())
            {
                if (row.ValueKind != JsonValueKind.Object) continue;
                string? Text(string key) => row.TryGetProperty(key, out var v) && v.ValueKind == JsonValueKind.String ? v.GetString() : null;
                var id = Text("id");
                if (string.IsNullOrEmpty(id) || id.Length > 1024 || id.Any(char.IsControl) || !ids.Add(id)) continue;
                DateTimeOffset? expiry = null; bool known = false;
                if (row.TryGetProperty("expiresAt", out var expires))
                {
                    known = expires.ValueKind == JsonValueKind.Null;
                    if (expires.ValueKind == JsonValueKind.Number && expires.TryGetInt64(out var seconds) && seconds is >= 0 and <= 253402300799)
                    { expiry = DateTimeOffset.FromUnixTimeSeconds(seconds); known = true; }
                }
                rows.Add(new(id, Text("resetType") ?? "unknown", Text("status") ?? "unknown", expiry, known));
            }
        }
        return new(count, rows);
    }
    public string CountLabel => $"重置卡 {AvailableCount} 张";
    public bool HasExpiredDetail(DateTimeOffset now) => Credits?.Any(c => c.Status == "available" && c.ExpiresAt <= now) == true;
    public string? PreferredId(DateTimeOffset now) => Credits?.Where(c => c.Usable(now)).OrderBy(c => c.ExpiresAt ?? DateTimeOffset.MaxValue).FirstOrDefault()?.Id;
    public string ExpiryLabel(DateTimeOffset now)
    {
        if (AvailableCount == 0) return "暂无可用卡";
        if (Credits is not { Count: > 0 }) return "有效期待确认";
        if (HasExpiredDetail(now)) return "有卡已到期 · 请刷新";
        var available = Credits.Where(c => c.Status == "available").ToArray();
        var complete = available.Length == AvailableCount && available.All(c => c.ExpiryKnown);
        var first = available.Where(c => c.ExpiresAt != null).Select(c => c.ExpiresAt!.Value).Order().Cast<DateTimeOffset?>().FirstOrDefault();
        if (first != null) return (complete ? "最近一张 " : "已知最早 ") + first.Value.ToLocalTime().ToString("MM-dd HH:mm") + " 到期";
        return complete ? "无到期限制" : "部分有效期待确认";
    }
    public string Details(DateTimeOffset now)
    {
        var rows = Credits?.Where(c => c.Status == "available").ToArray() ?? [];
        if (rows.Length == 0) return CountLabel + "\n服务暂未返回每张卡的有效期。";
        var lines = rows.Select((c, i) => $"第 {i + 1} 张 · " + (c.ExpiresAt is { } d ? d.ToLocalTime().ToString("yyyy-MM-dd HH:mm zzz") + (d <= now ? " 已到期" : " 到期") : c.ExpiryKnown ? "无到期限制" : "有效期待确认"));
        return CountLabel + "\n" + string.Join("\n", lines) + (rows.Length < AvailableCount ? "\n仅返回部分卡片详情，其余有效期待确认。" : "");
    }
    public static bool CanStart(QuotaState state, DateTimeOffset now) => state.Snapshot?.ResetCredits is { AvailableCount: > 0 } cards &&
        !state.Loading && !state.IsStale(now) && !cards.HasExpiredDetail(now);
}

public sealed record ResetAttempt(string IdempotencyKey, string? CreditId, DateTimeOffset CreatedAt)
{
    public static ResetAttempt? Prepare(ResetAttempt? existing, QuotaState state, bool confirmed, DateTimeOffset now, DateTimeOffset? lastResetAt = null)
    {
        if (!confirmed) return null;
        if (existing != null)
        {
            if (!Guid.TryParse(existing.IdempotencyKey, out _)) throw new UserError("上次请求记录异常，请先在官方用量页核对。");
            return existing;
        }
        if (lastResetAt != null && (state.Snapshot?.FetchedAt ?? DateTimeOffset.MinValue) <= lastResetAt) throw new UserError("账号已完成过一次重置，请重新刷新卡片后再操作。");
        if (!ResetCredits.CanStart(state, now)) throw new UserError("请先刷新重置卡信息，确认存在可用卡。");
        return new(Guid.NewGuid().ToString(), state.Snapshot?.ResetCredits?.PreferredId(now), now);
    }
}
public enum ResetOutcome { Reset, NothingToReset, NoCredit, AlreadyRedeemed }
public static class ResetProtocol
{
    public static string Message(ResetOutcome outcome) => outcome switch {
        ResetOutcome.Reset => "已使用 1 张重置卡 · 额度已重置",
        ResetOutcome.AlreadyRedeemed => "上次重置已生效 · 本次未重复扣卡",
        ResetOutcome.NothingToReset => "当前额度无需重置 · 未消耗重置卡",
        _ => "官方服务显示暂无可用重置卡"
    };
    public static async Task<ResetOutcome> ConsumeAsync(IQuotaRpc rpc, QuotaCredentials credentials, ResetAttempt attempt, CancellationToken cancellation)
    {
        await rpc.CallAsync("initialize", new { clientInfo = new { name = "still_reset_cards", version = "1.0.0" }, capabilities = new { experimentalApi = true } }, cancellation);
        await rpc.NotifyAsync("initialized", cancellation);
        var login = await rpc.CallAsync("account/login/start", new { type = "chatgptAuthTokens", accessToken = credentials.AccessToken, chatgptAccountId = credentials.AccountId, chatgptPlanType = credentials.Plan }, cancellation);
        if (!login.TryGetProperty("type", out var type) || type.GetString() != "chatgptAuthTokens") throw new UserError("官方 CLI 登录协议不匹配；请求标识已保留。");
        var result = await rpc.CallAsync("account/rateLimitResetCredit/consume", new { idempotencyKey = attempt.IdempotencyKey, creditId = attempt.CreditId }, cancellation);
        if (result.ValueKind != JsonValueKind.Object || !result.TryGetProperty("outcome", out var value) || value.ValueKind != JsonValueKind.String) throw new UserError("重置结果待确认；本次请求标识已保留。");
        return value.GetString() switch { "reset" => ResetOutcome.Reset, "nothingToReset" => ResetOutcome.NothingToReset,
            "noCredit" => ResetOutcome.NoCredit, "alreadyRedeemed" => ResetOutcome.AlreadyRedeemed,
            _ => throw new UserError("重置结果待确认；本次请求标识已保留。") };
    }
}
public sealed class ResetBroker(string cli, string root, Action<string, bool>? secure = null)
{
    public async Task<ResetOutcome> RunAsync(byte[] auth, string key, ResetAttempt attempt, CancellationToken cancellation,
        Func<string, QuotaProcess>? factory = null, TimeSpan? timeout = null)
    {
        var credentials = QuotaCredentials.Read(auth, key);
        SafeFiles.CheckPath(root);
        var parent = Path.Combine(root, "reset-requests"); Directory.CreateDirectory(parent); secure?.Invoke(parent, true);
        var dir = Path.Combine(parent, Guid.NewGuid().ToString()); Directory.CreateDirectory(dir);
        try
        {
            secure?.Invoke(dir, true);
            if (!OperatingSystem.IsWindows()) File.SetUnixFileMode(dir, UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute);
            using var deadline = CancellationTokenSource.CreateLinkedTokenSource(cancellation); deadline.CancelAfter(timeout ?? TimeSpan.FromSeconds(45));
            await using var rpc = factory?.Invoke(dir) ?? new QuotaProcess(DiagnosticBroker.CreateStartInfo(cli, dir));
            return await ResetProtocol.ConsumeAsync(rpc, credentials, attempt, deadline.Token);
        }
        catch (OperationCanceledException) when (!cancellation.IsCancellationRequested) { throw new UserError("重置请求超时，结果待确认；沿用上次请求核对，避免重复扣卡。"); }
        finally { SafeFiles.CheckPath(dir); if (Directory.Exists(dir)) Directory.Delete(dir, true); }
    }
}
