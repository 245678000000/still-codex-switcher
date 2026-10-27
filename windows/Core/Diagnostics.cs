using System.Text.Json;
using System.Diagnostics;
namespace Still.Core;

public enum DiagnosticLevel { Passed, Attention, Unknown }
public sealed record DiagnosticCheck(string Id, string Title, DiagnosticLevel Level, string Detail);
// Memory-only, no raw errors, credentials, prompts or persistent account changes.
public sealed record DiagnosticReport(DateTimeOffset CheckedAt, IReadOnlyList<DiagnosticCheck> Checks, QuotaSnapshot? Quota = null, IReadOnlyList<string>? Models = null)
{
    public const string Boundary = "基础检查不发送聊天消息。模型目录不等于实际推理验证；本结果不是风控或模型身份判定。";
    public bool IsStale(DateTimeOffset now) => now < CheckedAt || now - CheckedAt >= TimeSpan.FromMinutes(5) ||
        Quota?.FiveHours?.ResetsAt <= now || Quota?.SevenDays?.ResetsAt <= now;
    public string Summary => Checks.Any(x => x.Level == DiagnosticLevel.Attention) ? "有项目需要处理" : Checks.Any(x => x.Level == DiagnosticLevel.Unknown) ? "部分项目待确认" : "基础检查已完成";
    public static DiagnosticReport FromQuota(QuotaSnapshot q)
    {
        var unknown = q.FiveHours == null || q.SevenDays == null;
        var empty = q.FiveHours?.RemainingPercent <= 0 || q.SevenDays?.RemainingPercent <= 0;
        return new(q.FetchedAt, [new("quota", "剩余额度", empty ? DiagnosticLevel.Attention : unknown ? DiagnosticLevel.Unknown : DiagnosticLevel.Passed,
            $"5 小时 {QuotaState.Percent(q.FiveHours)} · 7 天 {QuotaState.Percent(q.SevenDays)}" + (empty ? " · 请等待官方重置" : unknown ? " · 缺失窗口保留为未知" : " · 以官方窗口为准"))], q);
    }
    public static DiagnosticReport Interrupted(string reason, DateTimeOffset? now = null) => new(now ?? DateTimeOffset.UtcNow,
        [new("execution", "本次检查未完成", DiagnosticLevel.Unknown, reason)]);
}

// Public JSON-RPC boundary shared by pipe fixtures and the app. Allowlisted read methods only.
public sealed class DiagnosticProtocol(QuotaCredentials credentials)
{
    int expected = 1, pages;
    readonly HashSet<string> cursors = [];
    readonly SortedSet<string> models = new(StringComparer.Ordinal);
    readonly List<DiagnosticCheck> checks = [new("credentials", "账号凭据", DiagnosticLevel.Passed, "本地资料与所选账号匹配；未刷新或回写凭证")];
    QuotaSnapshot? quota;
    public DiagnosticReport? Result { get; private set; }
    public static object Initialize => new { id = 1, method = "initialize", @params = new { clientInfo = new { name = "still_account_diagnostics", version = "1.0.0" }, capabilities = new { experimentalApi = true } } };
    object ModelsRequest(string? cursor = null) => new { id = 4, method = "model/list", @params = new { limit = 100, includeHidden = false, cursor } };
    void Finish(DateTimeOffset now) => Result = new(now, checks.ToArray(), quota, models.ToArray());
    public IReadOnlyList<object> Receive(JsonElement obj, DateTimeOffset now)
    {
        if (Result != null) return [];
        if (obj.ValueKind != JsonValueKind.Object) throw new UserError("诊断响应格式异常。");
        if (obj.TryGetProperty("method", out var method))
        {
            if (obj.TryGetProperty("id", out _))
            {
                checks.Add(new("request", "官方服务", DiagnosticLevel.Attention, method.GetString() == "account/chatgptAuthTokens/refresh"
                    ? "访问令牌需更新，请在 Codex 登录后更新备份或重新添加账号" : "组件请求了额外操作，检查已停止")); Finish(now);
            }
            return [];
        }
        if (!obj.TryGetProperty("id", out var id) || !id.TryGetInt32(out var n) || n != expected) return [];
        if (obj.TryGetProperty("error", out var error))
        {
            int? code = error.ValueKind == JsonValueKind.Object && error.TryGetProperty("code", out var c) && c.TryGetInt32(out var v) ? v : null;
            string reason = code switch { -32601 or -32602 => "CLI 协议不兼容，请更新官方 Codex", 401 => "服务返回认证失败，请更新登录备份", 403 => "服务拒绝本次访问，请到官方客户端核对；原因待确认", 429 => "请求受限，请稍后重试；额度与频率限制需分别核对", _ => "请求未完成，请检查网络、登录备份及 CLI 版本；原因待确认" };
            checks.Add(new(expected == 4 ? "models" : "service", expected == 4 ? "模型目录" : "官方额度接口", DiagnosticLevel.Attention, reason));
            if (expected == 3) { expected = 4; return [ModelsRequest()]; }
            Finish(now); return [];
        }
        if (!obj.TryGetProperty("result", out var result) || result.ValueKind != JsonValueKind.Object) throw new UserError("诊断响应缺少结果。");
        switch (expected)
        {
            case 1:
                expected = 2; return [new { method = "initialized" }, new { id = 2, method = "account/login/start", @params = new { type = "chatgptAuthTokens", accessToken = credentials.AccessToken, chatgptAccountId = credentials.AccountId, chatgptPlanType = credentials.Plan } }];
            case 2:
                if (!result.TryGetProperty("type", out var type) || type.GetString() != "chatgptAuthTokens") throw new UserError("诊断临时登录协议不匹配。");
                expected = 3; return [new { id = 3, method = "account/rateLimits/read" }];
            case 3:
                quota = QuotaSnapshot.Parse(result, now);
                checks.Add(new("service", "官方额度接口", DiagnosticLevel.Passed, "本次额度读取成功；不代表所有模型请求均可用"));
                checks.AddRange(DiagnosticReport.FromQuota(quota).Checks);
                expected = 4; return [ModelsRequest()];
            case 4:
                if (!result.TryGetProperty("data", out var data) || data.ValueKind != JsonValueKind.Array || data.GetArrayLength() > 100) throw new UserError("模型目录响应格式异常。");
                foreach (var model in data.EnumerateArray())
                    if (model.ValueKind == JsonValueKind.Object && model.TryGetProperty("model", out var name) && name.ValueKind == JsonValueKind.String &&
                        name.GetString() is { Length: > 0 and <= 120 } text && text.All(ch => char.IsAsciiLetterOrDigit(ch) || "-._/".Contains(ch)) &&
                        !(model.TryGetProperty("hidden", out var hidden) && hidden.ValueKind == JsonValueKind.True)) models.Add(text);
                pages++;
                var next = result.TryGetProperty("nextCursor", out var nc) && nc.ValueKind == JsonValueKind.String ? nc.GetString() : null;
                if (!string.IsNullOrEmpty(next) && next.Length <= 4096 && pages < 4 && cursors.Add(next)) return [ModelsRequest(next)];
                var partial = !string.IsNullOrEmpty(next);
                checks.Add(new("models", "模型目录", models.Count == 0 || partial ? DiagnosticLevel.Unknown : DiagnosticLevel.Passed,
                    models.Count == 0 ? "未返回可展示模型；尚未验证实际推理" : $"读取到 {models.Count} 个模型标识" + (partial ? " · 列表未完整返回" : "") + " · 可能来自 CLI 缓存，尚未验证实际推理"));
                Finish(now); return [];
        }
        return [];
    }
}

public sealed class DiagnosticBroker(string cli, string root, Action<string, bool>? secure = null)
{
    public static ProcessStartInfo CreateStartInfo(string cli, string dir)
    {
        var start = QuotaProcess.CreateStartInfo(cli, dir);
        var preserved = start.Environment.Where(x => new[] { "PATH", "SYSTEMROOT", "WINDIR", "COMSPEC", "LANG" }.Contains(x.Key.ToUpperInvariant())).ToArray();
        start.Environment.Clear(); foreach (var item in preserved) start.Environment[item.Key] = item.Value;
        start.Environment["HOME"] = dir; start.Environment["USERPROFILE"] = dir; start.Environment["CODEX_HOME"] = dir;
        start.Environment["CODEX_SQLITE_HOME"] = Path.Combine(dir, "state");
        start.Environment["APPDATA"] = dir; start.Environment["LOCALAPPDATA"] = dir;
        start.Environment["XDG_CONFIG_HOME"] = dir; start.Environment["XDG_DATA_HOME"] = dir; start.Environment["XDG_CACHE_HOME"] = dir;
        start.Environment["TMP"] = dir; start.Environment["TEMP"] = dir; start.Environment["TMPDIR"] = dir;
        return start;
    }
    public async Task<DiagnosticReport> RunAsync(byte[] auth, string key, CancellationToken cancellation,
        Func<string, IWarmupTransport>? factory = null, TimeSpan? timeout = null)
    {
        var credentials = QuotaCredentials.Read(auth, key);
        SafeFiles.CheckPath(root);
        var parent = Path.Combine(root, "diagnostic-queries"); SafeFiles.CheckPath(parent); Directory.CreateDirectory(parent); secure?.Invoke(parent, true);
        var dir = Path.Combine(parent, Guid.NewGuid().ToString()); Directory.CreateDirectory(dir);
        try
        {
            secure?.Invoke(dir, true);
            if (!OperatingSystem.IsWindows()) File.SetUnixFileMode(dir, UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute);
            using var deadline = CancellationTokenSource.CreateLinkedTokenSource(cancellation); deadline.CancelAfter(timeout ?? TimeSpan.FromSeconds(45));
            deadline.Token.ThrowIfCancellationRequested();
            await using var rpc = factory?.Invoke(dir) ?? new QuotaProcess(CreateStartInfo(cli, dir));
            var state = new DiagnosticProtocol(credentials);
            await rpc.SendAsync(DiagnosticProtocol.Initialize, deadline.Token);
            while (state.Result == null)
                foreach (var message in state.Receive(await rpc.ReadAsync(deadline.Token), DateTimeOffset.UtcNow)) await rpc.SendAsync(message, deadline.Token);
            return state.Result;
        }
        catch (OperationCanceledException) { return DiagnosticReport.Interrupted(cancellation.IsCancellationRequested ? "已取消 · 本次未发送聊天消息" : "检查超时 · 请检查网络后手动重试"); }
        catch { return DiagnosticReport.Interrupted("组件检查未完成，请检查官方 CLI 与网络；本次没有自动重试"); }
        finally { SafeFiles.CheckPath(dir); if (Directory.Exists(dir)) Directory.Delete(dir, true); }
    }
}
