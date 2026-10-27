using System.IO;
using System.Security.Cryptography;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using Still.Core;
namespace Still.Windows;
public partial class MainWindow
{
    readonly Dictionary<Guid, DiagnosticReport> diagnostics = [];
    readonly HashSet<Guid> expandedDiagnosticModels = [];
    CancellationTokenSource? diagnosticCancel;
    Guid? diagnosing;
    void ShowDiagnostics(object sender, RoutedEventArgs e)
    {
        AccountsPage.Visibility = SettingsPage.Visibility = TokensPage.Visibility = Visibility.Collapsed;
        AccountsNav.Background = SettingsNav.Background = TokensNav.Background = Brushes.Transparent;
        DiagnosticsPage.Visibility = Visibility.Visible; DiagnosticsNav.SetResourceReference(BackgroundProperty, "WashBrush");
        Breadcrumb.Text = "工作台   /   账号诊断"; RenderDiagnostics(); MainScroll.ScrollToTop();
    }
    void HideDiagnostics() { DiagnosticsPage.Visibility = Visibility.Collapsed; DiagnosticsNav.Background = Brushes.Transparent; }
    static TextBlock DiagnosticText(string text, double size = 11, bool muted = true)
    {
        var t = new TextBlock { Text = text, FontSize = size, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 0, 0, 8) };
        t.SetResourceReference(ForegroundProperty, muted ? "MutedBrush" : "InkBrush"); return t;
    }
    void RenderDiagnostics()
    {
        if (!initialized) return;
        DiagnosticsPage.Children.Clear();
        var heading = DiagnosticText("状态有据，不靠猜测。", 29, false); heading.FontWeight = FontWeights.SemiBold;
        DiagnosticsPage.Children.Add(DiagnosticText("OBSERVE. DON'T GUESS.", 11)); DiagnosticsPage.Children.Add(heading);
        DiagnosticsPage.Children.Add(DiagnosticText("逐项检查账号连接与额度。不切换账号，不发送聊天消息。", 12));
        DiagnosticsPage.Children.Add(DiagnosticText(DiagnosticReport.Boundary));
        if (library.Accounts.Count == 0) DiagnosticsPage.Children.Add(DiagnosticText("先在账号空间保存或添加一个账号，再进行检查。", 13));
        foreach (var account in library.Accounts)
        {
            var body = new StackPanel();
            var card = new Border { Child = body, Style = (Style)FindResource("Card"), Margin = new Thickness(0, 12, 0, 4) };
            var header = new DockPanel();
            var button = new Button { Content = diagnosing == account.Id ? "取消检查" : "基础检查…", FontSize = 11, VerticalAlignment = VerticalAlignment.Center,
                IsEnabled = diagnosing == account.Id || !busy && !refreshingQuotas && ready };
            DockPanel.SetDock(button, Dock.Right);
            button.Click += async (_, _) => { if (diagnosing == account.Id) diagnosticCancel?.Cancel(); else await DiagnoseAsync(account); };
            header.Children.Add(button);
            var identity = new StackPanel(); var name = DiagnosticText(account.Label, 14, false); name.FontWeight = FontWeights.SemiBold;
            identity.Children.Add(name); identity.Children.Add(DiagnosticText(account.Email, 10)); header.Children.Add(identity); body.Children.Add(header);
            if (diagnosing == account.Id) body.Children.Add(DiagnosticText("正在检查 · 如有旧结果，以下为上次记录"));
            if (diagnostics.TryGetValue(account.Id, out var report))
            {
                var status = DiagnosticText(report.Summary + "   ·   " + (report.IsStale(DateTimeOffset.UtcNow) ? "上次结果 " : "本次检查 ") + report.CheckedAt.ToLocalTime().ToString("HH:mm:ss"), 11, false);
                status.Margin = new Thickness(0, 14, 0, 14); body.Children.Add(status);
                foreach (var item in report.Checks)
                {
                    var label = DiagnosticText((item.Level == DiagnosticLevel.Passed ? "✓  " : item.Level == DiagnosticLevel.Attention ? "!  " : "?  ") + item.Title, 11, false);
                    label.FontWeight = FontWeights.SemiBold; body.Children.Add(label);
                    var detail = DiagnosticText(item.Detail, 10.5); detail.Margin = new Thickness(15, 0, 0, 12); body.Children.Add(detail);
                }
                if (report.Models is { Count: > 0 })
                {
                    var expander = new Expander { Header = $"查看模型标识（{report.Models.Count}）", FontSize = 11, IsExpanded = expandedDiagnosticModels.Contains(account.Id),
                        Content = DiagnosticText(string.Join(" · ", report.Models), 10) };
                    expander.Expanded += (_, _) => expandedDiagnosticModels.Add(account.Id);
                    expander.Collapsed += (_, _) => expandedDiagnosticModels.Remove(account.Id);
                    body.Children.Add(expander);
                }
            }
            else body.Children.Add(DiagnosticText("尚未检查 · 点击后先确认，再连接官方服务"));
            DiagnosticsPage.Children.Add(card);
        }
        var experimental = new StackPanel(); experimental.Children.Add(DiagnosticText("模型指纹 · 实验性 · 尚未接入", 12, false));
        experimental.Children.Add(DiagnosticText("基础诊断不含指纹评分。参考库验证完成后再单独提供手动测试；届时会先说明请求数量与额度消耗。指纹相似度不是官方风控状态，也不证明当前聊天的模型身份。"));
        DiagnosticsPage.Children.Add(new Border { Child = experimental, Style = (Style)FindResource("Card"), Margin = new Thickness(0, 18, 0, 0) });
    }
    async Task DiagnoseAsync(Account account)
    {
        if (busy || refreshingQuotas || !ready) return;
        if (demo) { ShowDemoDiagnostics(); StatusText.Text = "演示诊断 · 没有读取凭据或发送请求"; return; }
        if (diagnostics.TryGetValue(account.Id, out var previous) && DateTimeOffset.UtcNow - previous.CheckedAt < TimeSpan.FromSeconds(30))
        { StatusText.Text = "检查刚刚完成，请等待 30 秒后重试。"; return; }
        if (!Confirm("检查「" + account.Label + "」？", "读取所选账号的本地凭据，再通过独立官方 CLI 查询额度和模型目录。不发送聊天消息，不触发预热，不切换或退出 Codex，也不刷新登录凭证。\n\n结果仅在本次运行期间保留；模型目录可能来自缓存，不代表实际推理验证。是否开始基础检查？")) return;
        if (busy || refreshingQuotas) { StatusText.Text = "其他检查已开始，请稍后重试。"; return; }
        using var cancel = new CancellationTokenSource(); diagnosticCancel = cancel; diagnosing = account.Id;
        try
        {
            await Run(async () =>
            {
                byte[]? auth = null;
                try
                {
                    var saved = library.Accounts.FirstOrDefault(a => a.Id == account.Id && a.IdentityKey == account.IdentityKey) ?? throw new UserError("账号记录已变化，请刷新列表。");
                    ConfigGuard.Check(paths.Config);
                    var live = SafeFiles.Read(paths.Auth);
                    if (live != null)
                    {
                        try { if (Identity.Read(live).Key == saved.IdentityKey) auth = live; }
                        catch (UserError) { }
                        finally { if (!ReferenceEquals(auth, live)) CryptographicOperations.ZeroMemory(live); }
                    }
                    auth ??= vault.Get(saved.Id.ToString()) ?? throw new UserError("登录备份缺失，请重新添加账号。");
                    _ = QuotaCredentials.Read(auth, saved.IdentityKey);
                    desktop ??= await Task.Run(() => DesktopTarget.DiscoverAsync(library.DesktopPath));
                    var cli = desktop?.FindCli(library.CliPath) ?? library.CliPath;
                    if (string.IsNullOrWhiteSpace(cli) || !File.Exists(cli)) throw new UserError("未找到官方 CLI，请到偏好中选择官方组件。");
                    StatusText.Text = "正在检查「" + saved.Label + "」…";
                    var report = await new DiagnosticBroker(cli, paths.Root, PrivateAccess.Set).RunAsync(auth, saved.IdentityKey, cancel.Token);
                    diagnostics[saved.Id] = cancel.IsCancellationRequested ? DiagnosticReport.Interrupted("已取消 · 本次未发送聊天消息") : report;
                }
                catch (Exception ex) { diagnostics[account.Id] = DiagnosticReport.Interrupted(ex is UserError ? ex.Message : "检查未完成，请检查官方 CLI、登录备份或网络；本次没有自动重试"); }
                finally { if (auth != null) CryptographicOperations.ZeroMemory(auth); }
                StatusText.Text = account.Label + "：" + diagnostics[account.Id].Summary + "。当前 Codex 登录保持原样。";
            });
        }
        finally { diagnosticCancel = null; diagnosing = null; RenderDiagnostics(); }
    }
    public void ShowDemoDiagnostics(bool empty = false)
    {
        if (!demo) return;
        diagnostics.Clear(); var now = DateTimeOffset.UtcNow;
        if (!empty) foreach (var (account, i) in library.Accounts.Select((a, i) => (a, i)))
        {
            var q = new QuotaSnapshot(new(i == 1 ? 0 : 76, now.AddHours(1)), i == 2 ? null : new(42, now.AddDays(1)), now);
            diagnostics[account.Id] = new(now, [new("credentials", "账号凭据", DiagnosticLevel.Passed, "本地资料与所选账号匹配；未刷新或回写凭证"),
                new("service", "官方额度接口", DiagnosticLevel.Passed, "本次额度读取成功；不代表所有模型请求均可用"), .. DiagnosticReport.FromQuota(q).Checks,
                new("models", "模型目录", DiagnosticLevel.Passed, "读取到 2 个模型标识 · 可能来自 CLI 缓存，尚未验证实际推理")], q, ["example-model-a", "example-model-b"]);
        }
        ShowDiagnostics(this, new RoutedEventArgs());
    }
    public bool CheckDemoDiagnostics()
    {
        if (!demo || DiagnosticsPage.Visibility != Visibility.Visible || diagnostics.Count != library.Accounts.Count ||
            !diagnostics.Values.Any(x => x.Checks.Any(c => c.Level == DiagnosticLevel.Attention)) ||
            !diagnostics.Values.Any(x => x.Checks.Any(c => c.Level == DiagnosticLevel.Unknown))) return false;
        Button[] Buttons() => DiagnosticsPage.Children.OfType<Border>().Select(x => x.Child).OfType<StackPanel>()
            .SelectMany(x => x.Children.OfType<DockPanel>()).SelectMany(x => x.Children.OfType<Button>()).ToArray();
        refreshingQuotas = true; RenderDiagnostics();
        var blocked = Buttons().Length == library.Accounts.Count && Buttons().All(x => !x.IsEnabled);
        refreshingQuotas = false; RenderDiagnostics();
        return blocked && Buttons().All(x => x.IsEnabled);
    }
}
