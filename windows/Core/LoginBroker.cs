using System.Diagnostics;
using System.Text.Json;

namespace Still.Core;
public sealed class LoginBroker(string cli, string root, Action<string, bool>? secure = null)
{
    public static bool ValidUrl(string value) => Uri.TryCreate(value, UriKind.Absolute, out var u) && u.Scheme == "https" && string.IsNullOrEmpty(u.UserInfo) &&
        new[] { "openai.com", "chatgpt.com" }.Any(h => u.Host.Equals(h, StringComparison.OrdinalIgnoreCase) || u.Host.EndsWith("." + h, StringComparison.OrdinalIgnoreCase));
    public async Task<byte[]> LoginAsync(Action<Uri> openBrowser, IProgress<string> status, CancellationToken cancellation)
    {
        SafeFiles.CheckPath(root);
        var parent = Path.Combine(root, "logins"); Directory.CreateDirectory(parent); secure?.Invoke(parent, true);
        // Caller holds the same operation lock as every other login/switch instance.
        foreach (var stale in Directory.EnumerateDirectories(parent))
        {
            if (!Guid.TryParseExact(Path.GetFileName(stale), "D", out _)) continue;
            SafeFiles.CheckPath(stale); Directory.Delete(stale, true);
        }
        var dir = Path.Combine(parent, Guid.NewGuid().ToString()); Directory.CreateDirectory(dir); secure?.Invoke(dir, true);
        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(cancellation); deadline.CancelAfter(TimeSpan.FromMinutes(5));
        using var p = new Process();
        p.StartInfo = new ProcessStartInfo(cli) { UseShellExecute = false, CreateNoWindow = true, RedirectStandardInput = true, RedirectStandardOutput = true, RedirectStandardError = true, WorkingDirectory = dir };
        foreach (var arg in new[] { "-c", "cli_auth_credentials_store=\"file\"", "app-server" }) p.StartInfo.ArgumentList.Add(arg);
        foreach (var key in new[] { "OPENAI_API_KEY", "CODEX_API_KEY", "CODEX_ACCESS_TOKEN", "CODEX_THREAD_ID", "CODEX_INTERNAL_ORIGINATOR_OVERRIDE" }) p.StartInfo.Environment.Remove(key);
        p.StartInfo.Environment["CODEX_HOME"] = dir;
        string? loginId = null; bool started = false;
        async Task Send(object value) { await p.StandardInput.WriteLineAsync(JsonSerializer.Serialize(value)); await p.StandardInput.FlushAsync(); }
        try
        {
            if (!p.Start()) throw new UserError("登录组件未启动，请检查官方 CLI 路径。"); started = true;
            // Drain without retaining messages: stderr can contain OAuth URLs or other sensitive data.
            var stderr = Task.Run(async () => { var buf = new char[4096]; while (await p.StandardError.ReadAsync(buf, deadline.Token) > 0) { } }, deadline.Token);
            _ = stderr.ContinueWith(t => _ = t.Exception, TaskContinuationOptions.OnlyOnFaulted);
            await Send(new { id = 1, method = "initialize", @params = new { clientInfo = new { name = "still_codex_switcher_windows", version = "1.0.0" } } });
            status.Report("正在打开官方登录页面…");
            while (true)
            {
                var line = await p.StandardOutput.ReadLineAsync(deadline.Token);
                if (line == null) throw new UserError("登录组件已结束，请重新添加。当前 Codex 账号保持原样。");
                if (line.Length > 2_000_000) throw new UserError("登录组件返回异常，本次登录已结束。");
                JsonDocument doc; try { doc = JsonDocument.Parse(line); } catch (JsonException) { continue; }
                using (doc)
                {
                    var obj = doc.RootElement;
                    if (obj.TryGetProperty("error", out _)) throw new UserError("官方登录组件报告错误。请检查网络、CLI 版本或端口占用后重试。");
                    var id = obj.TryGetProperty("id", out var i) && i.TryGetInt32(out var n) ? n : 0;
                    if (id == 1)
                    {
                        await Send(new { method = "initialized" });
                        await Send(new { id = 2, method = "account/login/start", @params = new { type = "chatgpt", useHostedLoginSuccessPage = true, appBrand = "codex" } });
                    }
                    else if (id == 2)
                    {
                        var r = obj.GetProperty("result"); var url = r.GetProperty("authUrl").GetString() ?? "";
                        loginId = r.GetProperty("loginId").GetString();
                        if (!ValidUrl(url) || string.IsNullOrEmpty(loginId)) throw new UserError("登录页面地址未通过检查。");
                        openBrowser(new Uri(url)); status.Report("等待你在浏览器登录要添加的账号…");
                    }
                    else if (obj.TryGetProperty("method", out var m) && m.GetString() == "account/login/completed")
                    {
                        var r = obj.GetProperty("params");
                        if (loginId == null || r.GetProperty("loginId").GetString() != loginId) continue;
                        if (!r.GetProperty("success").GetBoolean()) throw new UserError("本次登录未完成，请重试。已有账号保持原样。");
                        var data = SafeFiles.Read(Path.Combine(dir, "auth.json")) ?? throw new UserError("登录完成但暂未找到凭据，请重新添加。");
                        _ = Identity.Read(data); return data;
                    }
                }
            }
        }
        catch (OperationCanceledException) { throw new UserError(cancellation.IsCancellationRequested ? "已取消添加，现有账号保持不变。" : "登录等待已超时，请重新添加。"); }
        finally
        {
            // Only the child launched in our private directory is stopped. No desktop process is killed.
            if (started && !p.HasExited)
            {
                try { if (loginId != null) await Send(new { id = 3, method = "account/login/cancel", @params = new { loginId } }); p.StandardInput.Close(); } catch { }
                try { using var wait = new CancellationTokenSource(TimeSpan.FromSeconds(3)); await p.WaitForExitAsync(wait.Token); }
                catch (OperationCanceledException) { if (!p.HasExited) { p.Kill(entireProcessTree: true); await p.WaitForExitAsync(); } }
            }
            deadline.Cancel(); SafeFiles.CheckPath(dir); Directory.Delete(dir, true);
        }
    }
}
