using System.IO;
using System.Windows;
using System.Windows.Controls;
using Still.Core;

namespace Still.Windows;
public partial class MainWindow
{
    Guid? warmingAccount;
    readonly Dictionary<Guid, string> warmupNotices = [];
    bool HasAutoWarmup => library.Accounts.Any(a => a.Warmup is { Enabled: true, Paused: false, ScheduleVersion: WarmupPolicy.Version });
    string WarmupStatus(Account a) => warmingAccount == a.Id ? "正在预热 · 可点击上方停止"
        : warmupNotices.GetValueOrDefault(a.Id) ?? WarmupPolicy.Status(a.Warmup ?? new());

    async void ToggleWarmup(object sender, RoutedEventArgs e)
    {
        if (sender is not CheckBox { Tag: Account account } || busy || refreshingQuotas) { RenderAccounts(); return; }
        var enabled = !(account.Warmup is { Enabled: true, ScheduleVersion: WarmupPolicy.Version });
        if (!demo && enabled && !Confirm("为「" + account.Label + "」开启自动预热？",
            "首次检查会尝试发送一条「回复ok」，之后至少间隔 5 小时，并参考服务端重置时间。使用 GPT-6 Luna / low，会消耗真实额度，也可能涉及账户计费；这不是补充额度。\n\n只在 5 小时有余额、7 天剩余至少 1% 时请求。不切换账号、不刷新或回写凭证。失败或结果不明会暂停。\n\n栖言运行且电脑唤醒时每 5 分钟检查；最小化继续，关闭窗口或退出程序后停止。是否开启？")) { RenderAccounts(); return; }
        void Update()
        {
            var index = library.Accounts.FindIndex(a => a.Id == account.Id);
            if (index < 0) throw new UserError("账号已移除，请刷新列表。");
            var next = library.Clone();
            var fresh = next.Accounts[index];
            next.Accounts[index] = fresh with { Warmup = (fresh.Warmup ?? new()) with
                { Enabled = enabled, Paused = false, ScheduleVersion = WarmupPolicy.Version, NextAt = null } };
            if (!demo) store.Save(next);
            library = next;
            warmupNotices.Remove(account.Id);
            StatusText.Text = enabled ? "已开启该账号的自动预热，准备检查额度。" : "已关闭该账号的自动预热。";
        }
        if (demo) { Update(); RenderAccounts(); return; }
        await Run(() => { Update(); return Task.CompletedTask; });
        if (enabled && library.Accounts.FirstOrDefault(a => a.Id == account.Id)?.Warmup?.Enabled == true) await RefreshQuotasAsync(account.Id, force: true);
    }
    async void WarmupOnce(object sender, RoutedEventArgs e)
    {
        if (sender is not Button { Tag: Account account } || busy || refreshingQuotas) return;
        if (demo) { StatusText.Text = "演示模式：没有发送模型请求。"; return; }
        if (!Confirm("检查并预热「" + account.Label + "」一次？",
            "确认后重新查询额度，再尝试发送一条「回复ok」。手动预热不等待 5 小时重置，前提是 5 小时有余额、7 天剩余至少 1%。会产生实际用量。\n\n如果窗口已在运行，这条消息不会让窗口重新开始；若上次结果不明，重试可能再次产生用量。每次手动请求至少间隔 60 秒。是否继续？")) return;
        warmupNotices[account.Id] = "正在检查额度…"; RenderAccounts();
        await RefreshQuotasAsync(account.Id, manualWarmup: true, force: true);
    }
    async Task AttemptWarmupAsync(Account account, QuotaSnapshot snapshot, string cli, bool manual, CancellationToken cancel)
    {
        if (busy || cancel.IsCancellationRequested || !ready) return;
        var fresh = library.Accounts.FirstOrDefault(a => a.Id == account.Id);
        if (fresh == null || (!manual && fresh.Warmup?.Enabled != true)) return;
        if (WarmupPolicy.Reason(fresh.Warmup ?? new(), snapshot, DateTimeOffset.UtcNow, manual) is { } reason)
        {
            if (manual) { warmupNotices[account.Id] = reason; StatusText.Text = account.Label + "：" + reason; }
            else if (fresh.Warmup?.Paused != true && WarmupPolicy.QuotaReason(snapshot, DateTimeOffset.UtcNow) is { } quotaReason) warmupNotices[account.Id] = quotaReason;
            else warmupNotices.Remove(account.Id);
            return;
        }
        warmingAccount = account.Id; warmupNotices.Remove(account.Id); SetBusy(true);
        StatusText.Text = "正在预热「" + account.Label + "」…";
        try
        {
            var result = await Task.Run(() => new WarmupService(paths, vault, PrivateAccess.Set).RunAsync(account, snapshot, manual,
                (auth, key, token) => new WarmupBroker(cli, paths.Root, PrivateAccess.Set).RunAsync(auth, key, token), cancel));
            library = result.Library;
            if (result.Result is { } reply) quotas[account.Id] = new(reply.Snapshot, AttemptedAt: DateTimeOffset.UtcNow);
            warmupNotices.Remove(account.Id);
            StatusText.Text = account.Label + "：" + result.Notice;
            if (result.Result == null || library.Accounts.First(a => a.Id == account.Id).Warmup?.Enabled != true)
                warmupNotices[account.Id] = result.Notice;
        }
        catch (Exception ex)
        {
            // Fail closed on preparation/save/lock errors. A persisted in-flight claim stays paused.
            ready = false;
            warmupNotices[account.Id] = "预热准备或状态保存未完成，自动操作已停止；请检查后重新打开。";
            StatusText.Text = ex is OperationCanceledException ? "预热已停止，请检查后重试。" : warmupNotices[account.Id];
        }
        finally { warmingAccount = null; SetBusy(false); Render(); }
    }
    void PauseWarmupAfterQueryFailure(Account account, string reason)
    {
        if (busy || library.Accounts.FirstOrDefault(a => a.Id == account.Id)?.Warmup?.Enabled != true) return;
        try
        {
            using var gate = new OperationLock(paths.Root);
            var next = store.Load(); var i = next.Accounts.FindIndex(a => a.Id == account.Id && a.IdentityKey == account.IdentityKey);
            if (i < 0 || next.Accounts[i].Warmup is not { Enabled: true } record) return;
            next.Accounts[i] = next.Accounts[i] with { Warmup = record with { Paused = true, Result = "自动预热已暂停 · " + reason } };
            store.Save(next); library = next;
        }
        catch { ready = false; StatusText.Text = "预热暂停状态保存未完成，自动操作已停止。请检查本地目录后重新打开。"; }
    }
    public void ShowDemoWarmup(bool bottom = false)
    {
        if (!demo) return;
        var now = DateTimeOffset.UtcNow;
        library.Accounts[0] = library.Accounts[0] with { Warmup = new(true, false, WarmupPolicy.Version, now.AddHours(-1), now.AddHours(4), "预热消息已发送 · 窗口状态以官方额度为准") };
        library.Accounts[1] = library.Accounts[1] with { Warmup = new(true, true, WarmupPolicy.Version, now.AddMinutes(-10), null, "自动预热已暂停 · 访问令牌已过期，请更新登录备份。") };
        // Keep the fixture focused on complete account cards instead of the top introduction.
        ShowAccounts(this, new RoutedEventArgs()); RenderAccounts();
        if (bottom) MainScroll.ScrollToBottom(); else MainScroll.ScrollToVerticalOffset(370);
    }
    public bool CheckDemoWarmup()
    {
        if (!demo) return false;
        var rows = AccountsList.Items.Cast<AccountRow>().ToArray();
        if (rows.Length != 3 || !rows[0].WarmupEnabled || !rows[0].WarmupText.Contains("下次不早于") ||
            !rows[1].WarmupText.Contains("已暂停") || rows[2].WarmupEnabled || !rows[2].WarmupText.Contains("默认关闭")) return false;
        ToggleWarmup(new CheckBox { Tag = library.Accounts[2] }, new RoutedEventArgs());
        var on = library.Accounts[2].Warmup?.Enabled == true;
        ToggleWarmup(new CheckBox { Tag = library.Accounts[2] }, new RoutedEventArgs());
        WarmupOnce(new Button { Tag = library.Accounts[0] }, new RoutedEventArgs());
        return on && library.Accounts[2].Warmup?.Enabled == false && StatusText.Text.Contains("没有发送模型请求");
    }
}
