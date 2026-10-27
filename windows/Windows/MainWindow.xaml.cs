using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Text.Json;
using System.Security.Cryptography;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using Microsoft.Win32;
using Still.Core;

namespace Still.Windows;
public partial class MainWindow : Window
{
    readonly bool demo;
    readonly Paths paths;
    readonly IVault vault;
    readonly AccountStore store;
    Library library = new(); Identity? current; DesktopTarget? desktop;
    bool busy, ready = true, initialized;
    CancellationTokenSource? loginCancel;
    CancellationTokenSource? quotaCancel;
    readonly Dictionary<Guid, QuotaState> quotas = [];
    readonly System.Windows.Threading.DispatcherTimer quotaTimer = new() { Interval = TimeSpan.FromMinutes(1) };
    bool refreshingQuotas;
    public MainWindow(bool demo)
    {
        this.demo = demo;
        var root = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "StillCodexSwitcher");
        var home = Environment.GetEnvironmentVariable("CODEX_HOME") ?? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".codex");
        paths = new(root, home);
        vault = new EncryptedVault(Path.Combine(root, "vault"), new WindowsProtector(), PrivateAccess.Set);
        store = new(paths, vault, PrivateAccess.Set);
        InitializeComponent();
        TokensPage.Configure(paths.CodexHome, demo);
        if (demo)
        {
            library.Accounts = new[] { ("Personal", "personal@example.com", "plus"), ("工作空间", "work@example.com", "team"), ("日常探索", "explore@example.com", "free") }.Select((v, i) => new Account(Guid.NewGuid(), "demo-" + i, v.Item1, v.Item2, v.Item3, DateTimeOffset.Now, i)).ToList();
            current = new("demo-0", "personal@example.com", "plus"); ModeLabel.Text = "●  演示模式 · 虚构账号          1.2";
            StatusText.Text = "界面演示：不读取真实账号，也不切换 Codex。";
            var now = DateTimeOffset.UtcNow;
            quotas[library.Accounts[0].Id] = new(new(new(76, now.AddHours(3)), new(42, now.AddDays(4)), now));
            quotas[library.Accounts[1].Id] = new(new(new(18, now.AddMinutes(40)), new(8, now.AddDays(1)), now));
        }
        else
        {
            SafeFiles.CheckPath(root); Directory.CreateDirectory(root); PrivateAccess.Set(root, true);
            try { library = store.Load(); } catch (Exception ex) { ready = false; StatusText.Text = ErrorText(ex); }
        }
        initialized = true; ApplyTheme(); Render();
        Loaded += async (_, _) => { if (!demo && ready) { await RefreshAsync(); await RefreshQuotasAsync(); quotaTimer.Start(); } };
        quotaTimer.Tick += async (_, _) =>
        {
            RenderAccounts();
            if (TokensPage.Visibility == Visibility.Visible && IsVisible && WindowState != WindowState.Minimized) await TokensPage.RefreshAsync();
            if (!demo && IsVisible && WindowState != WindowState.Minimized && !busy && !refreshingQuotas)
                await RefreshQuotasAsync(onlyDue: true);
        };
        Closed += (_, _) => { quotaTimer.Stop(); quotaCancel?.Cancel(); TokensPage.Cancel(); };
    }
    static string ErrorText(Exception ex) => ex is UserError ? ex.Message : ex is UnauthorizedAccessException ? "目录或进程访问受限。请使用普通用户运行，并检查路径权限。" : "操作未完成（" + ex.GetType().Name + "）。请检查使用说明与本地目录，账号凭据不会写入错误日志。";
    async Task Run(Func<Task> action, bool reload = true)
    {
        if (busy) return;
        if (demo) { StatusText.Text = "演示模式：正式运行时才会读写账号或重启 Codex。"; return; }
        if (!ready) { MessageBox.Show(this, "账号列表尚未成功读取，原文件已保留。请检查本地数据目录后重新打开。", "操作提示"); return; }
        try
        {
            using var gate = new OperationLock(paths.Root);
            if (reload) library = store.Load();
            SetBusy(true); await action();
        }
        catch (Exception ex) { StatusText.Text = ErrorText(ex); MessageBox.Show(this, ErrorText(ex), "操作提示", MessageBoxButton.OK, MessageBoxImage.Information); }
        finally { loginCancel?.Dispose(); loginCancel = null; SetBusy(false); Render(); }
    }
    void SetBusy(bool value)
    {
        busy = value; SaveButton.IsEnabled = !value && ready; AddButton.IsEnabled = !value && ready;
        QuotaRefreshButton.IsEnabled = !value && !refreshingQuotas && ready;
        CancelLoginButton.Visibility = loginCancel != null ? Visibility.Visible : Visibility.Collapsed;
        RenderAccounts();
    }
    async Task RefreshAsync()
    {
        await Run(async () =>
        {
            StatusText.Text = "正在检测本机 Codex…";
            desktop = await Task.Run(() => DesktopTarget.DiscoverAsync(library.DesktopPath));
            ReadCurrent(); StatusText.Text = desktop == null ? "暂未检测到 Codex。请先打开一次，或到「偏好与说明」选择程序路径。" : "本机配置已刷新。账号与订阅状态以 Codex 中显示为准。";
        });
    }
    void ReadCurrent()
    {
        ConfigGuard.Check(paths.Config); var data = SafeFiles.Read(paths.Auth); current = data == null ? null : Identity.Read(data);
    }
    void Render()
    {
        if (!initialized) return;
        SidebarCount.Text = library.Accounts.Count.ToString();
        var active = library.Accounts.FirstOrDefault(a => a.IdentityKey == current?.Key);
        CurrentName.Text = active?.Label ?? (current == null ? "先让一个账号就位" : "当前 Codex 账号");
        CurrentEmail.Text = current?.Email ?? "在 Codex 登录后保存，或通过下方添加账号。";
        SaveButton.Content = active == null ? "保存当前账号" : "更新登录备份";
        VersionLabel.Text = desktop == null ? "CODEX · WINDOWS" : "CODEX " + desktop.Version.Split('+')[0];
        DesktopPathLabel.Text = "桌面程序：" + (demo ? "演示数据" : desktop?.Exe ?? library.DesktopPath ?? "尚未找到");
        CliPathLabel.Text = "登录组件：" + (demo ? "演示数据" : desktop?.FindCli(library.CliPath) ?? library.CliPath ?? "添加账号时需要官方 codex.exe");
        HomeLabel.Text = demo ? "演示模式：不读写真实数据" : "当前登录目录：" + paths.CodexHome + "\n本地账号库：" + paths.Root;
        RenderAccounts();
    }
    void RenderAccounts()
    {
        if (!initialized) return;
        var filtered = library.Accounts.Where(a => (a.Label + a.Email).Contains(SearchBox.Text ?? "", StringComparison.OrdinalIgnoreCase));
        foreach (var id in quotas.Keys.Where(id => !library.Accounts.Any(a => a.Id == id)).ToArray()) quotas.Remove(id);
        var rows = filtered.Select(a => new AccountRow(a, a.IdentityKey == current?.Key, busy, IsDark(), quotas.GetValueOrDefault(a.Id) ?? new(), refreshingQuotas)).ToList();
        AccountsList.ItemsSource = rows;
        EmptyState.Visibility = library.Accounts.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
        NoMatches.Visibility = library.Accounts.Count > 0 && rows.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
    }
    void SearchChanged(object sender, TextChangedEventArgs e) => RenderAccounts();
    void ShowAccounts(object sender, RoutedEventArgs e)
    {
        TokensPage.Visibility = Visibility.Collapsed; TokensNav.Background = Brushes.Transparent;
        AccountsPage.Visibility = Visibility.Visible; SettingsPage.Visibility = Visibility.Collapsed;
        AccountsNav.SetResourceReference(BackgroundProperty, "WashBrush"); SettingsNav.Background = Brushes.Transparent; Breadcrumb.Text = "工作台   /   账号空间";
    }
    void ShowSettings(object sender, RoutedEventArgs e)
    {
        TokensPage.Visibility = Visibility.Collapsed; TokensNav.Background = Brushes.Transparent;
        AccountsPage.Visibility = Visibility.Collapsed; SettingsPage.Visibility = Visibility.Visible;
        SettingsNav.SetResourceReference(BackgroundProperty, "WashBrush"); AccountsNav.Background = Brushes.Transparent; Breadcrumb.Text = "工作台   /   偏好与说明";
    }
    async void SaveCurrent(object sender, RoutedEventArgs e) => await Run(() =>
    {
        ConfigGuard.Check(paths.Config);
        var data = SafeFiles.Read(paths.Auth) ?? throw new UserError("请先在 Windows 版 Codex 登录一次，再保存当前账号。");
        library = store.Capture(library, data); ReadCurrent(); StatusText.Text = "当前账号已加密保存。现在可以继续添加其他账号。"; return Task.CompletedTask;
    });
    async void AddAccount(object sender, RoutedEventArgs e) => await Run(async () =>
    {
        desktop ??= await Task.Run(() => DesktopTarget.DiscoverAsync(library.DesktopPath));
        var cli = desktop?.FindCli(library.CliPath) ?? library.CliPath;
        if (string.IsNullOrWhiteSpace(cli) || !File.Exists(cli)) throw new UserError("尚未找到官方登录组件。请在「偏好与说明」中选择 Codex 安装目录内的官方 codex.exe。");
        loginCancel = new(); CancelLoginButton.IsEnabled = true; CancelLoginButton.Visibility = Visibility.Visible;
        var data = await new LoginBroker(cli, paths.Root, PrivateAccess.Set).LoginAsync(uri => Process.Start(new ProcessStartInfo(uri.AbsoluteUri) { UseShellExecute = true }), new Progress<string>(text => StatusText.Text = text), loginCancel.Token);
        library = store.Capture(library, data);
        StatusText.Text = "账号已加密保存；重复账号会更新原记录。当前 Codex 未切换。";
    });
    void CancelLogin(object sender, RoutedEventArgs e) { loginCancel?.Cancel(); CancelLoginButton.IsEnabled = false; }
    bool Confirm(string title, string text) => MessageBox.Show(this, text, title, MessageBoxButton.YesNo, MessageBoxImage.Warning, MessageBoxResult.No) == MessageBoxResult.Yes;
    async void SwitchAccount(object sender, RoutedEventArgs e)
    {
        if (busy || ((Button)sender).Tag is not Account a) return;
        if (demo) { StatusText.Text = "演示模式：这里会先确认，再保存备份、切换并重启 Codex。"; return; }
        if (!Confirm("切换到「" + a.Label + "」？", "这会退出并重新打开 Codex，运行中的任务可能中断。\n\n请先保存工作，并结束其他共享登录目录的 Codex CLI 会话。切换前会保存当前账号最新凭据。\n\n是否继续？")) return;
        await Run(async () =>
        {
            var saved = library.Accounts.FirstOrDefault(x => x.Id == a.Id) ?? throw new UserError("这个账号已被移除，请刷新列表。");
            var data = vault.Get(a.Id.ToString()) ?? throw new UserError("未找到该账号凭据，请重新添加账号。");
            if (Identity.Read(data).Key != saved.IdentityKey) throw new UserError("保存的账号与凭据不匹配，请重新添加。");
            await SwitchTo(data, saved.Label);
        });
    }
    async Task SwitchTo(byte[] data, string label)
    {
        ConfigGuard.Check(paths.Config); var target = Identity.Read(data);
        desktop = await Task.Run(() => DesktopTarget.DiscoverAsync(library.DesktopPath)) ?? throw new UserError("未找到 Codex，请在设置里选择桌面程序。");
        var live = SafeFiles.Read(paths.Auth);
        if (live != null && Identity.Read(live).Key == target.Key) { library = store.Capture(library, live); ReadCurrent(); StatusText.Text = "当前已是这个账号，已更新其最新登录备份。"; return; }
        var progress = new Progress<string>(text => StatusText.Text = text);
        await desktop.QuitAsync(progress);
        try
        {
            StatusText.Text = "备份当前账号的最新登录状态…";
            var fresh = SafeFiles.Read(paths.Auth); if (fresh != null) library = store.Capture(library, fresh);
            StatusText.Text = "替换登录配置并重新打开 Codex…";
            await new SwitchTransaction(paths.Auth, vault, PrivateAccess.Set).ReplaceAsync(data, desktop.LaunchAsync);
        }
        catch { try { await desktop.LaunchAsync(); } catch { } throw; }
        library.LastSwitch = DateTimeOffset.Now;
        try { store.Save(library); }
        catch { StatusText.Text = "Codex 已启动，但列表时间保存未完成。回滚备份仍然保留。"; ReadCurrent(); return; }
        ReadCurrent(); StatusText.Text = "已载入「" + label + "」并启动 Codex。请在 Codex 头像中核对账号；过期登录需重新验证。";
    }
    async void RestoreAccount(object sender, RoutedEventArgs e)
    {
        if (busy) return;
        if (demo) { StatusText.Text = "演示模式：这里可以恢复上一次切换前的账号。"; return; }
        if (!Confirm("恢复上次切换前的账号？", "这会退出并重新打开 Codex。请保存任务并结束其他 Codex CLI 会话。当前配置也会先备份。\n\n是否继续？")) return;
        await Run(async () =>
        {
            var data = vault.Get("rollback") ?? throw new UserError("暂无回滚备份。");
            var backup = JsonSerializer.Deserialize<Rollback>(data);
            if (backup?.Original == null) throw new UserError("上一次切换前没有登录账号，请自行在 Codex 登录。");
            await SwitchTo(backup.Original, "上次账号");
        });
    }
    void AccountMenu(object sender, RoutedEventArgs e)
    {
        if (busy || ((Button)sender).Tag is not Account a) return;
        var menu = new ContextMenu(); var rename = new MenuItem { Header = "修改账号备注" }; var remove = new MenuItem { Header = "移除保存记录…" };
        rename.Click += async (_, _) =>
        {
            var label = AskName(a.Label); if (label == null) return;
            if (demo) { var i = library.Accounts.IndexOf(a); library.Accounts[i] = a with { Label = label }; Render(); return; }
            await Run(() => { library = store.Rename(library, a.Id, label); return Task.CompletedTask; });
        };
        remove.Click += async (_, _) =>
        {
            if (demo) { StatusText.Text = "演示账号保持原样。"; return; }
            if (!Confirm("移除「" + a.Label + "」？", "仅删除切换器保存的账号与加密凭据。Codex 当前登录、聊天记录和订阅保持原样；独立的上次回滚备份仍保留。\n\n是否移除？")) return;
            await Run(() => { library = store.Remove(library, a.Id); StatusText.Text = "保存记录已移除，当前 Codex 登录保持原样。"; return Task.CompletedTask; });
        };
        menu.Items.Add(rename); menu.Items.Add(remove); menu.PlacementTarget = (Button)sender; menu.IsOpen = true;
    }
    string? AskName(string initial)
    {
        var dialog = new Window { Title = "修改账号备注", Owner = this, Width = 410, Height = 220, ResizeMode = ResizeMode.NoResize, WindowStartupLocation = WindowStartupLocation.CenterOwner, Background = (Brush)FindResource("BackgroundBrush") };
        var panel = new StackPanel { Margin = new Thickness(24) }; var text = new TextBox { Text = initial, MaxLength = 40, Margin = new Thickness(0, 15, 0, 18) };
        panel.Children.Add(new TextBlock { Text = "给账号一个熟悉的名字", FontSize = 19 }); panel.Children.Add(text);
        var row = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right };
        var cancel = new Button { Content = "取消", IsCancel = true, Margin = new Thickness(0, 0, 9, 0) }; var save = new Button { Content = "保存", IsDefault = true };
        save.Click += (_, _) => { if (!string.IsNullOrWhiteSpace(text.Text)) dialog.DialogResult = true; };
        row.Children.Add(cancel); row.Children.Add(save); panel.Children.Add(row); dialog.Content = panel;
        dialog.Loaded += (_, _) => { text.Focus(); text.SelectAll(); };
        return dialog.ShowDialog() == true ? text.Text.Trim() : null;
    }
    async void ShowTokens(object sender, RoutedEventArgs e)
    {
        AccountsPage.Visibility = Visibility.Collapsed; SettingsPage.Visibility = Visibility.Collapsed; TokensPage.Visibility = Visibility.Visible;
        AccountsNav.Background = Brushes.Transparent; SettingsNav.Background = Brushes.Transparent;
        TokensNav.SetResourceReference(BackgroundProperty, "WashBrush"); Breadcrumb.Text = "工作台   /   Token 统计"; MainScroll.ScrollToTop();
        await TokensPage.RefreshAsync();
    }
    public void ShowDemoTokens(bool empty = false)
    {
        if (!demo) return;
        TokensPage.SeedDemo(empty); ShowTokens(this, new RoutedEventArgs());
    }
    public bool CheckDemoTokens() => demo && TokensPage.CheckDemoUI();
    public void ShowDemoQuotaList() { if (demo) MainScroll.ScrollToBottom(); }
    public void SetDemoTheme(string theme) { if (demo) { library.Theme = theme; ApplyTheme(); Render(); } }
    bool IsDark()
    {
        if (library.Theme == "dark") return true; if (library.Theme == "light") return false;
        try { return Registry.GetValue(@"HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize", "AppsUseLightTheme", 1) is int n && n == 0; } catch { return false; }
    }
    void ApplyTheme()
    {
        string[] names = ["Background", "Sidebar", "Surface", "Ink", "Muted", "Line", "Accent", "Wash", "Button", "ButtonText"];
        string[] colors = IsDark() ? ["#181E1B", "#202823", "#242D27", "#E4EDE7", "#A1B3A7", "#354039", "#8EC5A1", "#30463A", "#A5CFB2", "#1D3527"] : ["#F8FAF9", "#EFF3F1", "#FFFFFF", "#243C32", "#6E8176", "#E1E8E3", "#326F54", "#E7F0E9", "#2E6049", "#FFFFFF"];
        for (var i = 0; i < names.Length; i++) Application.Current.Resources[names[i] + "Brush"] = new SolidColorBrush((Color)ColorConverter.ConvertFromString(colors[i]));
        TokensPage.Paint();
    }
    async void ThemeClick(object sender, RoutedEventArgs e)
    {
        var theme = (string)((Button)sender).Tag;
        if (demo) { library.Theme = theme; ApplyTheme(); Render(); return; }
        await Run(() => { library.Theme = theme; store.Save(library); ApplyTheme(); StatusText.Text = "外观已更新。"; return Task.CompletedTask; });
    }
    async void DetectClick(object sender, RoutedEventArgs e) => await RefreshAsync();
    async void RefreshClick(object sender, RoutedEventArgs e) => await RefreshAsync();
    async void RefreshAllQuotas(object sender, RoutedEventArgs e) => await RefreshQuotasAsync();
    async void RefreshAccountQuota(object sender, RoutedEventArgs e)
    {
        if (((Button)sender).Tag is Account account) await RefreshQuotasAsync(account.Id);
    }
    void CancelQuotas(object sender, RoutedEventArgs e) => quotaCancel?.Cancel();
    async Task RefreshQuotasAsync(Guid? selected = null, bool onlyDue = false)
    {
        if (busy || refreshingQuotas || !ready) return;
        if (demo) { StatusText.Text = "演示额度为虚构数据；正式运行从官方服务查询。"; return; }
        var now = DateTimeOffset.UtcNow;
        var targets = library.Accounts.Where(a => selected == null || a.Id == selected).Where(a =>
            !quotas.TryGetValue(a.Id, out var state) || state.AttemptedAt == null || now - state.AttemptedAt >= TimeSpan.FromSeconds(onlyDue ? 300 : 30)).ToArray();
        if (targets.Length == 0) { if (!onlyDue) StatusText.Text = "额度刚刚刷新过，请稍后再试。"; return; }
        refreshingQuotas = true; quotaCancel = new();
        QuotaRefreshButton.IsEnabled = false; CancelQuotaButton.Visibility = Visibility.Visible;
        var cancel = quotaCancel.Token;
        try
        {
            // Only metadata/vault reads hold the operation lock. Network work does not block switching.
            var cli = desktop?.FindCli(library.CliPath) ?? library.CliPath;
            foreach (var account in targets)
            {
                if (cancel.IsCancellationRequested) break;
                var old = quotas.GetValueOrDefault(account.Id) ?? new();
                quotas[account.Id] = old with { Loading = true, AttemptedAt = DateTimeOffset.UtcNow }; RenderAccounts();
                try
                {
                    if (string.IsNullOrWhiteSpace(cli) || !File.Exists(cli)) throw new UserError("请在设置中选择官方 CLI 后刷新额度。");
                    byte[]? auth = null;
                    try
                    {
                        using (var gate = new OperationLock(paths.Root))
                        {
                            if (!store.Load().Accounts.Any(a => a.Id == account.Id && a.IdentityKey == account.IdentityKey)) { quotas.Remove(account.Id); continue; }
                            // Prefer the live access token only when identity matches. Never write the live auth file.
                            ConfigGuard.Check(paths.Config);
                            var live = SafeFiles.Read(paths.Auth);
                            if (live != null)
                            {
                                try { if (Identity.Read(live).Key == account.IdentityKey) auth = live; }
                                catch (UserError) { }
                                finally { if (!ReferenceEquals(auth, live)) CryptographicOperations.ZeroMemory(live); }
                            }
                            auth ??= vault.Get(account.Id.ToString());
                        }
                        if (auth == null) throw new UserError("登录备份缺失，请重新添加账号。");
                        var snapshot = await Task.Run(() => new QuotaBroker(cli, paths.Root, PrivateAccess.Set).ReadAsync(auth, account.IdentityKey, cancel), cancel);
                        if (library.Accounts.Any(a => a.Id == account.Id && a.IdentityKey == account.IdentityKey))
                            quotas[account.Id] = new(snapshot, AttemptedAt: DateTimeOffset.UtcNow);
                    }
                    finally { if (auth != null) CryptographicOperations.ZeroMemory(auth); }
                }
                catch (Exception ex)
                {
                    if (library.Accounts.Any(a => a.Id == account.Id && a.IdentityKey == account.IdentityKey))
                        quotas[account.Id] = old with { Error = ex is OperationCanceledException ? "已取消刷新" : ex is UserError ? ex.Message : "查询未完成，请检查网络或登录状态。", Loading = false, AttemptedAt = DateTimeOffset.UtcNow };
                }
                RenderAccounts();
            }
            if (!busy && !onlyDue) StatusText.Text = cancel.IsCancellationRequested ? "已停止额度刷新；上次结果保留。" : "额度刷新结束，各账号状态见卡片。查询没有切换或重启 Codex。";
        }
        catch (Exception)
        {
            if (!busy) StatusText.Text = "额度查询未完成，请检查官方 CLI 路径或稍后重试。";
        }
        finally
        {
            refreshingQuotas = false; quotaCancel?.Dispose(); quotaCancel = null;
            QuotaRefreshButton.IsEnabled = !busy && ready; CancelQuotaButton.Visibility = Visibility.Collapsed; RenderAccounts();
        }
    }
    async void ChooseDesktop(object sender, RoutedEventArgs e)
    {
        if (busy || demo) return;
        var picker = new OpenFileDialog { Title = "选择官方 Codex 桌面程序（Codex.exe 或 ChatGPT.exe）", Filter = "应用程序 (*.exe)|*.exe" };
        if (picker.ShowDialog(this) != true) return;
        await Run(() => { if (!DesktopTarget.LooksOfficial(picker.FileName)) throw new UserError("程序的名称或发行者信息与 Codex 不符。请选择从官方安装的桌面程序。"); library.DesktopPath = picker.FileName; store.Save(library); desktop = new(picker.FileName); StatusText.Text = "已保存 Codex 程序路径。"; return Task.CompletedTask; });
    }
    async void ChooseCli(object sender, RoutedEventArgs e)
    {
        if (busy || demo) return;
        var picker = new OpenFileDialog { Title = "选择 Codex 安装目录内的官方 CLI（codex.exe）", Filter = "Codex CLI (codex.exe)|codex.exe" };
        if (picker.ShowDialog(this) != true) return;
        await Run(() =>
        {
            if (!Path.GetFileName(picker.FileName).Equals("codex.exe", StringComparison.OrdinalIgnoreCase) || string.Equals(picker.FileName, desktop?.Exe, StringComparison.OrdinalIgnoreCase)) throw new UserError("请选择登录组件 codex.exe，而不是 Codex 桌面主程序。");
            library.CliPath = picker.FileName; store.Save(library); StatusText.Text = "已保存登录组件路径。请确保它来自官方 Codex 安装。"; return Task.CompletedTask;
        });
    }
    async void OpenCodex(object sender, RoutedEventArgs e) => await Run(async () =>
    {
        desktop ??= await Task.Run(() => DesktopTarget.DiscoverAsync(library.DesktopPath));
        if (desktop == null) throw new UserError("尚未找到 Codex，请在「偏好与说明」选择程序路径。");
        await desktop.LaunchAsync(); StatusText.Text = "已启动 Codex。";
    });
    void OnKeyDown(object sender, KeyEventArgs e)
    {
        if (Keyboard.Modifiers != ModifierKeys.Control || busy) return;
        if (e.Key == Key.S) { SaveCurrent(sender, e); e.Handled = true; }
        else if (e.Key == Key.N) { AddAccount(sender, e); e.Handled = true; }
        else if (e.Key == Key.F) { ShowAccounts(sender, e); SearchBox.Focus(); e.Handled = true; }
    }
    void OnClosing(object? sender, CancelEventArgs e)
    {
        if (refreshingQuotas) { quotaCancel?.Cancel(); e.Cancel = true; StatusText.Text = "正在结束额度查询，完成后可关闭。"; return; }
        if (!busy) return; e.Cancel = true;
        if (loginCancel != null) { loginCancel.Cancel(); StatusText.Text = "正在结束登录并清理临时资料，完成后可关闭。"; }
        else StatusText.Text = "当前操作正在完成，请稍后再关闭。";
    }
}
public sealed class AccountRow(Account account, bool current, bool busy, bool dark, QuotaState quota, bool refreshing)
{
    public Account Account => account;
    public string Label => account.Label;
    public string Email => account.Email;
    public string Plan => account.Plan.ToUpperInvariant();
    public string Initial => string.IsNullOrEmpty(Label) ? "·" : Label[..1].ToUpperInvariant();
    public string SwitchText => current ? "✓ 当前配置" : "切换并重启 →";
    public bool CanSwitch => !current && !busy;
    public bool CanRefresh => !busy && !refreshing;
    public string QuotaStatus => quota.Status(DateTimeOffset.UtcNow);
    public string FivePercent => QuotaState.Percent(quota.Snapshot?.FiveHours);
    public string SevenPercent => QuotaState.Percent(quota.Snapshot?.SevenDays);
    public double FiveValue => quota.Snapshot?.FiveHours?.RemainingPercent ?? 0;
    public double SevenValue => quota.Snapshot?.SevenDays?.RemainingPercent ?? 0;
    public string FiveReset => QuotaState.Reset(quota.Snapshot?.FiveHours, DateTimeOffset.UtcNow);
    public string SevenReset => QuotaState.Reset(quota.Snapshot?.SevenDays, DateTimeOffset.UtcNow);
    public double QuotaOpacity => quota.IsStale(DateTimeOffset.UtcNow) ? 0.55 : 1;
    public Brush FiveColor => QuotaColor(quota.Snapshot?.FiveHours);
    public Brush SevenColor => QuotaColor(quota.Snapshot?.SevenDays);
    Brush QuotaColor(QuotaWindow? w) => (Brush)new BrushConverter().ConvertFromString(w == null ? dark ? "#69796F" : "#BCC9C0" : w.RemainingPercent <= 10 ? dark ? "#ED9290" : "#B94343" : w.RemainingPercent <= 25 ? dark ? "#E1B875" : "#A57626" : dark ? "#8EC5A1" : "#326F54")!;
    public Brush BorderColor => (Brush)new BrushConverter().ConvertFromString(current ? dark ? "#486650" : "#B8D1C1" : dark ? "#354039" : "#E1E8E3")!;
    public Brush AvatarColor => (Brush)new BrushConverter().ConvertFromString(new[] { "#54896A", "#799BAE", "#AE9471", "#A48FAA" }[Math.Abs(account.Color % 4)])!;
    public Brush AvatarBackground => new SolidColorBrush(Color.FromArgb(26, ((SolidColorBrush)AvatarColor).Color.R, ((SolidColorBrush)AvatarColor).Color.G, ((SolidColorBrush)AvatarColor).Color.B));
}
