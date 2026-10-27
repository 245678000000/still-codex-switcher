using System.Security.Cryptography;
using System.Text.Json;

namespace Still.Core;

// Older libraries have no record: opt-in is always per account, never inferred.
public sealed record WarmupRecord(bool Enabled = false, bool Paused = false, int ScheduleVersion = 0,
    DateTimeOffset? LastAttempt = null, DateTimeOffset? NextAt = null, string? Result = null);

public static class WarmupPolicy
{
    public const string Model = "gpt-6-luna";
    public const int Version = 2;
    public static string? QuotaReason(QuotaSnapshot? q, DateTimeOffset now)
    {
        if (q == null || now < q.FetchedAt || now - q.FetchedAt >= TimeSpan.FromSeconds(90)) return "额度数据待刷新";
        if (q.FiveHours?.ResetsAt == null) return "未提供 5 小时窗口，暂不预热";
        if (q.FiveHours.RemainingPercent <= 0) return "5 小时额度已用完，请等待重置";
        if (q.SevenDays == null || q.SevenDays.RemainingPercent < 1 || q.SevenDays.ResetsAt == null || q.SevenDays.ResetsAt <= now)
            return "7 天额度不足 1% 或数据待确认";
        return null;
    }
    public static string? Reason(WarmupRecord r, QuotaSnapshot? q, DateTimeOffset now, bool manual = false)
    {
        if (!manual && !r.Enabled) return "自动预热已关闭";
        if (!manual && r.ScheduleVersion != Version) return "规则已更新，请重新开启自动预热";
        if (!manual && r.Paused) return "自动预热已暂停，请检查后手动重试";
        if (QuotaReason(q, now) is { } reason) return reason;
        if (r.LastAttempt is { } attempt)
        {
            if (now < attempt) return "本机时间异常，请检查后重试";
            if (now - attempt < TimeSpan.FromSeconds(manual ? 60 : 18000)) return "请求冷却中，稍后再检查";
        }
        if (!manual && r.NextAt > now) return "等待下次预热时间";
        return null;
    }
    public static DateTimeOffset NextAfterSuccess(DateTimeOffset attempt, QuotaSnapshot q)
    {
        var cooldown = attempt.AddSeconds(18060);
        return q.FiveHours?.ResetsAt is { } reset && reset.AddMinutes(1) > cooldown ? reset.AddMinutes(1) : cooldown;
    }
    public static string Status(WarmupRecord r)
    {
        var stamp = r.LastAttempt?.ToLocalTime().ToString("MM-dd HH:mm") is { } time ? time + " · " : "";
        if (r.Enabled && r.ScheduleVersion != Version) return "预热规则已更新，请重新开启开关确认";
        if (!r.Enabled) return r.Result == null ? "默认关闭 · 开启后会产生实际用量" : "自动关闭 · " + stamp + r.Result;
        if (r.Paused) return stamp + (r.Result ?? "已暂停，请检查后重试");
        return stamp + (r.Result ?? "等待首次预热") + (r.NextAt is { } next ? " · 下次不早于 " + next.ToLocalTime().ToString("MM-dd HH:mm") : "");
    }
}

public sealed record WarmupResult(QuotaSnapshot Snapshot, bool Sent, string Message);
public sealed record WarmupExecution(Library Library, WarmupResult? Result, string Notice);

// Own the cross-process lock for the complete attempt. Persist a paused claim BEFORE a turn.
// No token rotation, credential copy on disk, switch transaction, or desktop process operation.
public sealed class WarmupService(Paths paths, IVault vault, Action<string, bool>? secure = null)
{
    public async Task<WarmupExecution> RunAsync(Account account, QuotaSnapshot snapshot, bool manual,
        Func<byte[], string, CancellationToken, Task<WarmupResult>> run, CancellationToken cancellation,
        Func<DateTimeOffset>? clock = null)
    {
        clock ??= () => DateTimeOffset.UtcNow;
        using var gate = new OperationLock(paths.Root);
        var library = SafeFiles.Load(paths.Metadata);
        var index = library.Accounts.FindIndex(a => a.Id == account.Id && a.IdentityKey == account.IdentityKey);
        if (index < 0) throw new UserError("账号记录已变化，请刷新列表。");
        var saved = library.Accounts[index]; var previous = saved.Warmup ?? new();
        if (WarmupPolicy.Reason(previous, snapshot, clock(), manual) is { } reason) return new(library, null, reason);
        cancellation.ThrowIfCancellationRequested();
        ConfigGuard.Check(paths.Config);
        byte[]? auth = null;
        try
        {
            var live = SafeFiles.Read(paths.Auth);
            if (live != null)
            {
                try { if (Identity.Read(live).Key == saved.IdentityKey) auth = live; }
                catch (UserError) { }
                finally { if (!ReferenceEquals(auth, live)) CryptographicOperations.ZeroMemory(live); }
            }
            auth ??= vault.Get(saved.Id.ToString()) ?? throw new UserError("登录备份缺失，请重新添加账号。");
            _ = QuotaCredentials.Read(auth, saved.IdentityKey);
            var record = previous with { LastAttempt = clock(), Paused = true, Result = "预热尝试已登记；若意外中断，请检查后手动重试" };
            library.Accounts[index] = saved with { Warmup = record };
            SafeFiles.Save(paths.Metadata, library, secure);
            WarmupResult? result = null;
            try
            {
                cancellation.ThrowIfCancellationRequested();
                result = await run(auth, saved.IdentityKey, cancellation);
                cancellation.ThrowIfCancellationRequested();
                record = result.Sent
                    ? record with { Paused = false, Result = result.Message, NextAt = WarmupPolicy.NextAfterSuccess(record.LastAttempt!.Value, result.Snapshot) }
                    : previous with { Result = result.Message };
            }
            catch (Exception ex)
            {
                record = record with { Paused = true, Result = ex is OperationCanceledException
                    ? "已停止 · 可能已产生用量，请检查后重试"
                    : ex is UserError ? "自动预热已暂停 · " + ex.Message : "预热结果不明，自动请求已暂停" };
            }
            library.Accounts[index] = saved with { Warmup = record };
            // If this fails, the persisted claim remains paused. Caller stops all automatic work.
            SafeFiles.Save(paths.Metadata, library, secure);
            return new(library, result, record.Result ?? "预热已结束");
        }
        finally { if (auth != null) CryptographicOperations.ZeroMemory(auth); }
    }
}

public interface IWarmupTransport : IAsyncDisposable
{
    Task SendAsync(object message, CancellationToken cancellation);
    Task<JsonElement> ReadAsync(CancellationToken cancellation);
}

public sealed class WarmupBroker(string cli, string root, Action<string, bool>? secure = null)
{
    public async Task<WarmupResult> RunAsync(byte[] auth, string expectedKey, CancellationToken cancellation,
        Func<string, IWarmupTransport>? transport = null, TimeSpan? timeout = null)
    {
        var credentials = QuotaCredentials.Read(auth, expectedKey);
        SafeFiles.CheckPath(root);
        var parent = Path.Combine(root, "warmup-requests");
        SafeFiles.CheckPath(parent); Directory.CreateDirectory(parent); secure?.Invoke(parent, true);
        var dir = Path.Combine(parent, Guid.NewGuid().ToString()); Directory.CreateDirectory(dir);
        try
        {
            secure?.Invoke(dir, true);
            if (!OperatingSystem.IsWindows()) File.SetUnixFileMode(dir, UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute);
            using var deadline = CancellationTokenSource.CreateLinkedTokenSource(cancellation);
            deadline.CancelAfter(timeout ?? TimeSpan.FromSeconds(90));
            deadline.Token.ThrowIfCancellationRequested();
            await using var rpc = transport?.Invoke(dir) ?? new QuotaProcess(cli, dir);
            var protocol = new WarmupProtocol(credentials, dir);
            await rpc.SendAsync(WarmupProtocol.Initialize, deadline.Token);
            while (true)
            {
                var step = protocol.Receive(await rpc.ReadAsync(deadline.Token), DateTimeOffset.UtcNow);
                if (step.Result != null) return step.Result;
                foreach (var message in step.Messages) await rpc.SendAsync(message, deadline.Token);
            }
        }
        catch (OperationCanceledException) when (!cancellation.IsCancellationRequested)
        { throw new UserError("预热超时，结果待确认；可能已产生用量，请检查后重试。"); }
        finally { SafeFiles.CheckPath(dir); if (Directory.Exists(dir)) Directory.Delete(dir, true); }
    }
}

public sealed record WarmupStep(object[] Messages, WarmupResult? Result = null);
public sealed class WarmupProtocol(QuotaCredentials credentials, string directory)
{
    int expected = 1, pages;
    string? threadId, turnId;
    // Notifications can precede the turn/start response; match by ID after the response arrives.
    readonly Dictionary<string, JsonElement> early = [];
    static string? Str(JsonElement e, string key) => e.ValueKind == JsonValueKind.Object && e.TryGetProperty(key, out var p) && p.ValueKind == JsonValueKind.String ? p.GetString() : null;
    static JsonElement Obj(JsonElement e, string key) => e.ValueKind == JsonValueKind.Object && e.TryGetProperty(key, out var p) ? p : default;
    static bool True(JsonElement e, string key) => Obj(e, key).ValueKind == JsonValueKind.True;
    static object Request(int id, string method, object? parameters = null) => new { id, method, @params = parameters };
    static WarmupStep Send(params object[] messages) => new(messages);
    public static object Initialize => Request(1, "initialize", new { clientInfo = new { name = "still_window_warmup", version = "1.3.0" }, capabilities = new { experimentalApi = true } });
    public WarmupStep Receive(JsonElement frame, DateTimeOffset now)
    {
        if (frame.ValueKind != JsonValueKind.Object) throw new UserError("预热响应格式异常。");
        var method = Str(frame, "method");
        if (method != null)
        {
            if (frame.TryGetProperty("id", out _)) throw new UserError(method == "account/chatgptAuthTokens/refresh"
                ? "访问令牌已过期，请更新登录备份或重新添加账号。" : "预热组件请求了额外操作，任务已停止。");
            var p = Obj(frame, "params");
            if (Str(p, "threadId") != threadId || threadId == null) return Send();
            if (method == "item/started" && Str(Obj(p, "item"), "type") is not ("userMessage" or "agentMessage" or "reasoning"))
                throw new UserError("预热出现额外工具操作，任务已停止。");
            if (method == "turn/completed")
            {
                if (expected == 6 && Str(Obj(p, "turn"), "id") is { } id && early.Count < 16) early[id] = p.Clone();
                if (expected == -1) return Completed(p);
            }
            return Send();
        }
        if (expected <= 0 || !frame.TryGetProperty("id", out var reply) || reply.ValueKind != JsonValueKind.Number || !reply.TryGetInt32(out var number) || number != expected) return Send();
        if (frame.TryGetProperty("error", out _))
        {
            // Never relay server error messages, prompts, or credentials.
            throw new UserError(expected >= 6 ? "消息请求或额度复查未完成，可能已产生用量；请检查后重试。"
                : "预热准备未完成，请检查网络、登录和官方 CLI 版本。");
        }
        var result = Obj(frame, "result");
        if (result.ValueKind != JsonValueKind.Object) throw new UserError("预热响应缺少结果。");
        switch (expected)
        {
            case 1:
                expected = 2;
                return Send(new { method = "initialized" }, Request(2, "account/login/start", new { type = "chatgptAuthTokens", accessToken = credentials.AccessToken, chatgptAccountId = credentials.AccountId, chatgptPlanType = credentials.Plan }));
            case 2:
                if (Str(result, "type") != "chatgptAuthTokens") throw new UserError("官方 CLI 的临时登录协议不匹配，请更新 Codex。");
                expected = 3; return Send(Request(3, "account/rateLimits/read"));
            case 3:
                var q = QuotaSnapshot.Parse(result, now);
                if (WarmupPolicy.QuotaReason(q, now) is { } reason) return new([], new(q, false, reason));
                expected = 4; return Send(Request(4, "model/list", new { limit = 100, includeHidden = false }));
            case 4:
                var models = Obj(result, "data"); JsonElement available = default;
                if (models.ValueKind == JsonValueKind.Array)
                    foreach (var model in models.EnumerateArray())
                        if (Str(model, "model") == WarmupPolicy.Model && !True(model, "hidden")) { available = model; break; }
                var efforts = Obj(available, "supportedReasoningEfforts");
                if (available.ValueKind == JsonValueKind.Object && efforts.ValueKind == JsonValueKind.Array && efforts.EnumerateArray().Any(e => Str(e, "reasoningEffort") == "low"))
                {
                    expected = 5;
                    return Send(Request(5, "thread/start", new { model = WarmupPolicy.Model, modelProvider = "openai", cwd = directory,
                        approvalPolicy = "never", sandbox = "read-only", ephemeral = true,
                        baseInstructions = "Reply exactly ok. Do not use tools or access files, commands, websites, or other accounts.",
                        developerInstructions = "This is a single minimal reply. Reply exactly ok.",
                        config = new Dictionary<string, object> { ["model_reasoning_effort"] = "low", ["web_search"] = "disabled", ["features.shell_tool"] = false, ["features.apps"] = false, ["features.multi_agent"] = false } }));
                }
                if (++pages < 4 && available.ValueKind != JsonValueKind.Object && Str(result, "nextCursor") is { Length: > 0 } cursor)
                    return Send(Request(4, "model/list", new { limit = 100, cursor, includeHidden = false }));
                throw new UserError("该账号暂未提供 GPT-6 Luna / low，预热已暂停；没有自动换用其他模型。");
            case 5:
                var thread = Obj(result, "thread"); threadId = Str(thread, "id");
                if (string.IsNullOrEmpty(threadId) || !True(thread, "ephemeral") || Str(result, "model") != WarmupPolicy.Model ||
                    Str(result, "modelProvider") != "openai" || Str(result, "cwd") != directory || Str(result, "approvalPolicy") != "never" || Str(Obj(result, "sandbox"), "type") != "readOnly")
                    throw new UserError("临时会话隔离检查未通过，未发送预热消息。");
                expected = 6;
                return Send(Request(6, "turn/start", new { threadId, input = new[] { new { type = "text", text = "回复ok" } }, model = WarmupPolicy.Model,
                    effort = "low", approvalPolicy = "never", sandboxPolicy = new { type = "readOnly", networkAccess = false } }));
            case 6:
                turnId = Str(Obj(result, "turn"), "id");
                if (string.IsNullOrEmpty(turnId)) throw new UserError("预热消息确认异常，请检查后重试。");
                expected = -1;
                return early.TryGetValue(turnId, out var completed) ? Completed(completed) : Send();
            case 7:
                expected = 0;
                return new([], new(QuotaSnapshot.Parse(result, now), true, "预热消息已发送 · 窗口状态以官方额度为准"));
            default: return Send();
        }
    }
    WarmupStep Completed(JsonElement p)
    {
        var turn = Obj(p, "turn");
        if (Str(turn, "id") != turnId) return Send();
        if (Str(turn, "status") != "completed") throw new UserError("预热请求未正常完成，可能已产生用量；请检查后重试。");
        expected = 7; return Send(Request(7, "account/rateLimits/read"));
    }
}
