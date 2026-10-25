using System.Diagnostics;
using System.Text.Json;

namespace Still.Core;

public sealed class QuotaBroker(string cli, string root, Action<string, bool>? secure = null)
{
    public async Task<QuotaSnapshot> ReadAsync(byte[] auth, string expectedKey, CancellationToken cancellation)
    {
        var credentials = QuotaCredentials.Read(auth, expectedKey);
        SafeFiles.CheckPath(root);
        var parent = Path.Combine(root, "quota-queries"); Directory.CreateDirectory(parent); secure?.Invoke(parent, true);
        var dir = Path.Combine(parent, Guid.NewGuid().ToString()); Directory.CreateDirectory(dir);
        try
        {
            secure?.Invoke(dir, true);
            if (!OperatingSystem.IsWindows()) File.SetUnixFileMode(dir, UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute);
            using var deadline = CancellationTokenSource.CreateLinkedTokenSource(cancellation); deadline.CancelAfter(TimeSpan.FromSeconds(30));
            await using var rpc = new QuotaProcess(cli, dir);
            return await QuotaProtocol.ReadAsync(rpc, credentials, deadline.Token);
        }
        catch (OperationCanceledException) when (!cancellation.IsCancellationRequested) { throw new UserError("额度查询超时，请稍后刷新。"); }
        finally { SafeFiles.CheckPath(dir); if (Directory.Exists(dir)) Directory.Delete(dir, true); }
    }
}

// One outstanding request per child. Tokens travel over redirected stdin only, never argv/env/files.
public sealed class QuotaProcess : IQuotaRpc, IAsyncDisposable
{
    readonly Process process;
    readonly Task drain;
    int nextId;
    public QuotaProcess(string cli, string isolatedHome)
    {
        var start = new ProcessStartInfo(cli) { UseShellExecute = false, CreateNoWindow = true, RedirectStandardInput = true, RedirectStandardOutput = true, RedirectStandardError = true, WorkingDirectory = isolatedHome };
        foreach (var arg in new[] { "-c", "cli_auth_credentials_store=\"ephemeral\"", "-c", "analytics.enabled=false", "app-server" }) start.ArgumentList.Add(arg);
        foreach (var key in new[] { "OPENAI_API_KEY", "CODEX_API_KEY", "CODEX_ACCESS_TOKEN", "OPENAI_BASE_URL", "CODEX_THREAD_ID", "CODEX_INTERNAL_ORIGINATOR_OVERRIDE" }) start.Environment.Remove(key);
        start.Environment["CODEX_HOME"] = isolatedHome;
        process = new Process { StartInfo = start };
        try { if (!process.Start()) throw new UserError("官方额度查询组件未启动。"); }
        catch { process.Dispose(); throw; }
        drain = Task.Run(async () => { var buffer = new char[4096]; while (await process.StandardError.ReadAsync(buffer) > 0) { } });
        _ = drain.ContinueWith(t => _ = t.Exception, TaskContinuationOptions.OnlyOnFaulted);
    }
    async Task SendAsync(object message, CancellationToken cancellation)
    {
        await process.StandardInput.WriteLineAsync(JsonSerializer.Serialize(message).AsMemory(), cancellation);
        await process.StandardInput.FlushAsync(cancellation);
    }
    public Task NotifyAsync(string method, CancellationToken cancellation) => SendAsync(new { method }, cancellation);
    public async Task<JsonElement> CallAsync(string method, object? parameters, CancellationToken cancellation)
    {
        var id = ++nextId;
        await SendAsync(new { id, method, @params = parameters }, cancellation);
        while (true)
        {
            var line = await process.StandardOutput.ReadLineAsync(cancellation);
            if (line == null) throw new UserError("额度查询组件已结束，请更新官方 Codex 或重试。");
            if (line.Length > 2_000_000) throw new UserError("额度响应过大，本次查询已结束。");
            using var doc = JsonDocument.Parse(line); var obj = doc.RootElement;
            if (obj.ValueKind != JsonValueKind.Object) throw new UserError("额度响应格式异常。");
            if (obj.TryGetProperty("method", out var serverMethod))
            {
                if (obj.TryGetProperty("id", out var serverId))
                {
                    await SendAsync(new { id = serverId.Clone(), error = new { code = -32601, message = "This viewer does not refresh tokens or run tools." } }, cancellation);
                    if (serverMethod.GetString() == "account/chatgptAuthTokens/refresh") throw new UserError("登录已过期，请更新登录备份或重新添加账号。");
                }
                continue;
            }
            if (!obj.TryGetProperty("id", out var replyId) || replyId.ValueKind != JsonValueKind.Number || !replyId.TryGetInt32(out var number) || number != id) continue;
            if (obj.TryGetProperty("error", out var error))
            {
                int? code = error.ValueKind == JsonValueKind.Object && error.TryGetProperty("code", out var c) && c.ValueKind == JsonValueKind.Number && c.TryGetInt32(out var n) ? n : null;
                // Do not relay server messages: they may contain credentials or private payloads.
                throw new UserError(code is -32601 or -32602 ? "当前 CLI 的额度查询协议不兼容，请更新官方 Codex。" : "额度查询失败，请检查网络或更新登录备份。");
            }
            if (!obj.TryGetProperty("result", out var result)) throw new UserError("额度响应缺少结果。");
            return result.Clone();
        }
    }
    public async ValueTask DisposeAsync()
    {
        try
        {
            if (!process.HasExited)
            {
                try { process.StandardInput.Close(); } catch { }
                using var stop = new CancellationTokenSource(TimeSpan.FromSeconds(2));
                try { await process.WaitForExitAsync(stop.Token); }
                catch (OperationCanceledException) { if (!process.HasExited) process.Kill(entireProcessTree: true); await process.WaitForExitAsync(); }
            }
            try { await drain; } catch { }
        }
        finally { process.Dispose(); }
    }
}
