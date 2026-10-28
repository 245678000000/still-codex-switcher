using System.IO;
using System.Security.Cryptography;
using System.Windows;
using System.Windows.Controls;
using Still.Core;
namespace Still.Windows;
public partial class MainWindow
{
    readonly Dictionary<Guid, string> resetNotices = [];
    Guid? resetting;
    async void UseResetCard(object sender, RoutedEventArgs e)
    {
        if (((Button)sender).Tag is not Account account || busy || refreshingQuotas || !ready) return;
        var state = quotas.GetValueOrDefault(account.Id) ?? new();
        if (account.ResetAttempt == null && !ResetCredits.CanStart(state, DateTimeOffset.UtcNow)) { StatusText.Text = "请先刷新重置卡信息。"; return; }
        var retry = account.ResetAttempt != null;
        var detail = retry ? "这会沿用上次请求标识核对结果；若上次尚未生效，将继续使用同一张卡。不会创建第二次消耗。" :
            "将为这个账号使用 1 张重置卡，恢复官方规则覆盖的额度。已使用的卡不返还，额度窗口时间可能变化。\n\n" + state.Snapshot?.ResetCredits?.Details(DateTimeOffset.UtcNow);
        if (!Confirm(retry ? "核对「" + account.Label + "」上次重置？" : "为「" + account.Label + "」使用 1 张重置卡？", account.Email + "\n\n" + detail + "\n\n不切换当前 Codex 账号，不购买付费重置。是否继续？")) return;
        if (busy || refreshingQuotas) { StatusText.Text = "其他操作已开始，请稍后重试。"; return; }
        if (demo) { StatusText.Text = "演示确认完成 · 未消耗真实重置卡"; return; }
        resetting = account.Id;
        try
        {
            await Run(async () =>
            {
                byte[]? auth = null;
                try
                {
                    var index = library.Accounts.FindIndex(a => a.Id == account.Id && a.IdentityKey == account.IdentityKey);
                    if (index < 0 || library.Accounts[index].ResetAttempt != account.ResetAttempt) throw new UserError("账号或上次请求已变化，请核对列表后重试。");
                    ConfigGuard.Check(paths.Config);
                    var live = SafeFiles.Read(paths.Auth);
                    if (live != null)
                    {
                        try { if (Identity.Read(live).Key == account.IdentityKey) auth = live; }
                        catch (UserError) { }
                        finally { if (!ReferenceEquals(auth, live)) CryptographicOperations.ZeroMemory(live); }
                    }
                    auth ??= vault.Get(account.Id.ToString()) ?? throw new UserError("登录备份缺失，请重新添加账号。");
                    _ = QuotaCredentials.Read(auth, account.IdentityKey);
                    desktop ??= await Task.Run(() => DesktopTarget.DiscoverAsync(library.DesktopPath));
                    var cli = desktop?.FindCli(library.CliPath) ?? library.CliPath;
                    if (string.IsNullOrWhiteSpace(cli) || !File.Exists(cli)) throw new UserError("请到偏好中选择官方 CLI 组件。");
                    var attempt = ResetAttempt.Prepare(account.ResetAttempt, state, true, DateTimeOffset.UtcNow, library.Accounts[index].LastResetAt)!;
                    var next = library.Clone(); next.Accounts[index] = next.Accounts[index] with { ResetAttempt = attempt };
                    store.Save(next); library = next;
                    resetNotices[account.Id] = "正在确认官方结果…"; RenderAccounts();
                    var outcome = await new ResetBroker(cli, paths.Root, PrivateAccess.Set).RunAsync(auth, account.IdentityKey, attempt, CancellationToken.None);
                    next = library.Clone(); next.Accounts[index] = next.Accounts[index] with { ResetAttempt = null, LastResetAt = DateTimeOffset.UtcNow };
                    store.Save(next); library = next;
                    quotas[account.Id] = new(); resetNotices[account.Id] = ResetProtocol.Message(outcome);
                    try
                    {
                        var updated = await new QuotaBroker(cli, paths.Root, PrivateAccess.Set).ReadAsync(auth, account.IdentityKey, CancellationToken.None);
                        quotas[account.Id] = new(updated, AttemptedAt: DateTimeOffset.UtcNow);
                    }
                    catch { resetNotices[account.Id] += " · 额度刷新未完成，请稍后刷新"; }
                }
                catch (Exception ex)
                {
                    resetNotices[account.Id] = library.Accounts.FirstOrDefault(a => a.Id == account.Id)?.ResetAttempt != null ?
                        "结果待确认 · 请核对上次请求，避免重复消耗" : ex is UserError ? ex.Message : "重置准备未完成，请稍后重试";
                }
                finally { if (auth != null) CryptographicOperations.ZeroMemory(auth); }
                StatusText.Text = resetNotices.GetValueOrDefault(account.Id) ?? "请核对重置状态";
            });
        }
        finally { resetting = null; RenderAccounts(); }
    }
    void SeedResetCards(bool pending = false)
    {
        if (!demo || library.Accounts.Count < 2) return;
        var now = DateTimeOffset.UtcNow;
        var id = library.Accounts[0].Id;
        quotas[id] = quotas[id] with { Snapshot = quotas[id].Snapshot! with { ResetCredits = new(2, [
            new("demo-card-a", "codexRateLimits", "available", now.AddDays(5), true),
            new("demo-card-b", "codexRateLimits", "available", now.AddDays(7), true)]) } };
        id = library.Accounts[1].Id; quotas[id] = quotas[id] with { Snapshot = quotas[id].Snapshot! with { ResetCredits = new(0, []) } };
        if (pending) library.Accounts[0] = library.Accounts[0] with { ResetAttempt = new(Guid.NewGuid().ToString(), "demo-card-a", now) };
    }
    public bool CheckDemoResetCards(bool pending = false)
    {
        if (!demo) return false;
        SeedResetCards(pending); RenderAccounts();
        var rows = AccountsList.ItemsSource.Cast<AccountRow>().ToArray();
        if (rows.Length != 3 || rows[0].ResetCount != "重置卡 2 张" || !rows[0].CanUseReset || rows[1].CanUseReset || rows[2].CanUseReset) return false;
        busy = true; RenderAccounts();
        bool locked = AccountsList.ItemsSource.Cast<AccountRow>().All(r => !r.CanUseReset);
        busy = false; RenderAccounts();
        return locked && (pending ? rows[0].ResetButton == "核对上次请求…" : rows[0].ResetButton == "使用一张…");
    }

}
