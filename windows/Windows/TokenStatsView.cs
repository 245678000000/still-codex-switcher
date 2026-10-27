using System.Globalization;
using System.IO;
using System.Text;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Media;
using Microsoft.Win32;
using Still.Core;

namespace Still.Windows;
public sealed class TokenStatsView : UserControl
{
    readonly StackPanel body = new(), results = new();
    readonly TextBlock status = Text("尚未载入统计", 11, muted: true);
    readonly Button refresh = new() { Content = "↻ 刷新", Margin = new(8, 0, 0, 0) }, export = new() { Content = "导出 CSV", IsEnabled = false };
    readonly Dictionary<TokenPeriod, Button> periods = [];
    readonly TokenLogScanner scanner = new();
    TokenSnapshot? snapshot;
    TokenPeriod period = TokenPeriod.Week;
    string home = "";
    bool demo, loading;
    CancellationTokenSource? cancel;
    public TokenStatsView()
    {
        Content = body;
        body.Children.Add(Text("A CLEARER VIEW OF YOUR USAGE.", 11, muted: true));
        body.Children.Add(Text("Token 消费统计", 29, weight: FontWeights.SemiBold, margin: new(0, 10, 0, 9)));
        body.Children.Add(Text("看清每次投入。仅统计本机 Codex 桌面端主会话。", 12, muted: true, margin: new(0, 0, 0, 24)));
        var toolbar = new DockPanel { Margin = new(0, 0, 0, 20), LastChildFill = false };
        DockPanel.SetDock(refresh, Dock.Right); toolbar.Children.Add(refresh);
        DockPanel.SetDock(export, Dock.Right); toolbar.Children.Add(export);
        var choices = new StackPanel { Orientation = Orientation.Horizontal };
        foreach (var (p, title) in new[] { (TokenPeriod.Today, "今日"), (TokenPeriod.Week, "近 7 天"), (TokenPeriod.Month, "近 30 天"), (TokenPeriod.All, "全部") })
        {
            var button = new Button { Content = title, Padding = new(12, 9, 12, 9), Margin = new(0, 0, 5, 0) };
            button.Click += (_, _) => { period = p; Paint(); };
            periods[p] = button; choices.Children.Add(button);
        }
        toolbar.Children.Add(choices); body.Children.Add(toolbar); body.Children.Add(results); body.Children.Add(status);
        refresh.Click += async (_, _) => await RefreshAsync(); export.Click += Export;
    }
    public void Configure(string directory, bool fixture) { home = directory; demo = fixture; }
    public void SeedDemo(bool empty = false) { demo = true; snapshot = empty ? new() : TokenSnapshot.Demo(); Paint(); }
    public void Cancel() => cancel?.Cancel();
    public async Task RefreshAsync()
    {
        if (loading) return;
        if (demo) { snapshot ??= TokenSnapshot.Demo(); Paint(); return; }
        loading = true; refresh.IsEnabled = false; export.IsEnabled = false; status.Text = "正在本机整理 Token 计数…不发送消息、不读取凭据。";
        cancel = new();
        try { snapshot = await Task.Run(() => scanner.Scan(home, cancel.Token)); Paint(); }
        catch (OperationCanceledException) { status.Text = "读取已停止，原有统计仍保留。"; }
        catch { status.Text = "本地日志读取未完成，请检查目录权限后重试。"; }
        finally { loading = false; refresh.IsEnabled = true; export.IsEnabled = snapshot != null; cancel.Dispose(); cancel = null; }
    }
    static string Number(long n) => n.ToString("N0", CultureInfo.InvariantCulture);
    internal static string Compact(long n) => n >= 1_000_000 ? (n / 1_000_000d).ToString("0.00", CultureInfo.InvariantCulture) + "M" : n >= 10_000 ? (n / 1000d).ToString("0.0", CultureInfo.InvariantCulture) + "K" : Number(n);
    static TextBlock Text(string text, double size = 12, bool muted = false, FontWeight? weight = null, Thickness? margin = null)
    {
        var t = new TextBlock { Text = text, FontSize = size, FontWeight = weight ?? FontWeights.Normal, TextWrapping = TextWrapping.Wrap, Margin = margin ?? new() };
        t.SetResourceReference(TextBlock.ForegroundProperty, muted ? "MutedBrush" : "InkBrush"); return t;
    }
    static Border Card(UIElement child)
    {
        var card = new Border { Child = child, Padding = new(21), CornerRadius = new(15), BorderThickness = new(1), Margin = new(0, 0, 0, 18) };
        card.SetResourceReference(BackgroundProperty, "SurfaceBrush"); card.SetResourceReference(Border.BorderBrushProperty, "LineBrush"); return card;
    }
    public void Paint()
    {
        foreach (var (p, b) in periods) b.SetResourceReference(BackgroundProperty, p == period ? "WashBrush" : "SurfaceBrush");
        results.Children.Clear(); export.IsEnabled = snapshot != null && !loading;
        if (snapshot == null) { results.Children.Add(Card(Text("正在准备本地统计…", 13, muted: true, margin: new(0, 50, 0, 50)))); return; }
        var summary = snapshot.Summarize(period);
        var top = new StackPanel();
        top.Children.Add(Text("所选区间 · TOTAL TOKENS", 11, muted: true));
        var headline = new DockPanel { Margin = new(0, 10, 0, 19) };
        var exact = new StackPanel { VerticalAlignment = VerticalAlignment.Center, HorizontalAlignment = HorizontalAlignment.Right };
        exact.Children.Add(Text(Number(summary.Total.Total) + " Tokens", 12));
        exact.Children.Add(Text($"{summary.SessionCount} 个有用量的主会话", 11, muted: true, margin: new(0, 7, 0, 0)));
        DockPanel.SetDock(exact, Dock.Right); headline.Children.Add(exact);
        var total = Text(Compact(summary.Total.Total), 42, weight: FontWeights.SemiBold); total.ToolTip = Number(summary.Total.Total); total.SetResourceReference(TextBlock.ForegroundProperty, "AccentBrush"); headline.Children.Add(total); top.Children.Add(headline);
        var metrics = new UniformGrid { Columns = 4, Margin = new(0, 16, 0, 0) };
        foreach (var (label, count, note) in new[] { ("输入", summary.Total.Input, "含缓存输入"), ("缓存输入", summary.Total.Cached, "输入的子集"), ("输出", summary.Total.Output, "含推理输出"), ("推理", summary.Total.Reasoning, "输出的子集") })
        {
            var column = new StackPanel(); column.Children.Add(Text(label, 11, muted: true));
            var value = Text(Compact(count), 21, weight: FontWeights.SemiBold, margin: new(0, 7, 0, 7)); value.ToolTip = Number(count); column.Children.Add(value); column.Children.Add(Text(note, 10, muted: true)); metrics.Children.Add(column);
        }
        var rule = new Border { BorderThickness = new(0, 1, 0, 0), Child = metrics }; rule.SetResourceReference(Border.BorderBrushProperty, "LineBrush"); top.Children.Add(rule); results.Children.Add(Card(top));
        var trend = new StackPanel(); trend.Children.Add(Text("每日趋势", 14, weight: FontWeights.SemiBold));
        trend.Children.Add(Text("输入 + 输出 · 本地时区 · 悬停查看每日明细", 10, muted: true, margin: new(0, 6, 0, 12)));
        if (summary.Total.Total == 0) trend.Children.Add(Text("此区间暂无可用的桌面端 Token 记录。\n其他设备、插件、CLI 与派生会话不在此统计范围。", 12, muted: true, margin: new(0, 45, 0, 45)));
        else trend.Children.Add(new TokenChart { Days = summary.Days, Height = 185 });
        results.Children.Add(Card(trend));
        var models = new StackPanel(); models.Children.Add(Text("模型分布", 14, weight: FontWeights.SemiBold, margin: new(0, 0, 0, 14)));
        if (summary.Models.Count == 0) models.Children.Add(Text("有用量后，这里会展示模型明细。", 11, muted: true));
        foreach (var m in summary.Models)
        {
            var row = new DockPanel();
            var share = Text(Number(m.Tokens.Total) + "   " + (100d * m.Tokens.Total / Math.Max(1, summary.Total.Total)).ToString("0.0", CultureInfo.InvariantCulture) + "%", 11);
            DockPanel.SetDock(share, Dock.Right); row.Children.Add(share);
            var name = Text(m.Name, 12); name.TextWrapping = TextWrapping.NoWrap; name.TextTrimming = TextTrimming.CharacterEllipsis; name.ToolTip = m.Name; row.Children.Add(name); models.Children.Add(row);
            var bar = new ProgressBar { Value = m.Tokens.Total, Maximum = Math.Max(1, summary.Total.Total), Height = 4, BorderThickness = new(), Margin = new(0, 7, 0, 14) };
            bar.SetResourceReference(ForegroundProperty, "AccentBrush"); bar.SetResourceReference(BackgroundProperty, "WashBrush"); models.Children.Add(bar);
        }
        results.Children.Add(Card(models));
        var notes = new StackPanel(); notes.Children.Add(Text("本机统计，不是订阅账单", 12, weight: FontWeights.SemiBold, margin: new(0, 0, 0, 10)));
        notes.Children.Add(Text("总量 = 输入 + 输出；缓存和推理已包含在其中，不重复相加。日志未记录的可选类别按 0 展示。Token 数不等于 5 小时 / 7 天额度，也不换算订阅费用。", 11, muted: true));
        notes.Children.Add(Text("历史会话可能跨账号继续使用，暂不按账号分摊。仅含来源明确的桌面端主会话；VS Code 插件、CLI、分叉/子代理、临时预热、WSL 和其他设备未计入。", 11, muted: true, margin: new(0, 8, 0, 0)));
        notes.Children.Add(Text($"已排除 {snapshot.ExcludedFiles} 份非主会话日志。" + (snapshot.Warnings > 0 ? $"另有 {snapshot.Warnings} 处读取或计数异常被跳过，当前结果可能不完整。" : ""), 11, muted: true, margin: new(0, 8, 0, 0)));
        notes.Children.Add(Text("数据目录：" + (demo ? "虚构演示数据" : home), 10, muted: true, margin: new(0, 8, 0, 0))); results.Children.Add(Card(notes));
        status.Text = $"{snapshot.FetchedAt.LocalDateTime:HH:mm} 更新 · 已扫描 {snapshot.ScannedFiles} 份日志 · 本页可见时每分钟刷新";
    }
    async void Export(object sender, RoutedEventArgs e)
    {
        if (snapshot == null) return;
        var csv = TokenCsv.Make(snapshot.Summarize(period));
        var dialog = new SaveFileDialog { Title = "导出本机每日 Token 统计", FileName = "Codex-Token-" + period + ".csv", Filter = "CSV 表格 (*.csv)|*.csv", DefaultExt = ".csv", AddExtension = true };
        if (dialog.ShowDialog(Window.GetWindow(this)) != true) return;
        try { await File.WriteAllTextAsync(dialog.FileName, csv, new UTF8Encoding(true)); status.Text = "CSV 已导出，仅含日期和数字汇总。"; }
        catch { status.Text = "导出未完成，请检查所选目录的写入权限。"; }
    }
    public bool CheckDemoUI()
    {
        if (!demo) return false;
        SeedDemo(); period = TokenPeriod.Today; Paint(); var today = snapshot!.Summarize(period).Total.Total;
        period = TokenPeriod.Week; Paint(); var week = snapshot.Summarize(period).Total.Total;
        period = TokenPeriod.Month; Paint(); var month = snapshot.Summarize(period).Total.Total;
        var ok = today == 865400 && week == 10693430 && month > week && export.IsEnabled && results.Children.Count == 4;
        SeedDemo(true); ok &= snapshot!.Summarize(period).Total.Total == 0 && results.Children.Count == 4;
        SeedDemo(); period = TokenPeriod.Week; Paint(); return ok;
    }
}
public sealed class TokenChart : FrameworkElement
{
    public IReadOnlyList<TokenDay> Days { get; init; } = [];
    public TokenChart()
    {
        MouseMove += (_, e) => {
            var width = ActualWidth - 56;
            if (Days.Count == 0 || width <= 0) return;
            var i = Math.Clamp((int)((e.GetPosition(this).X - 52) / width * Days.Count), 0, Days.Count - 1);
            var day = Days[i]; ToolTip = $"{day.Date:yyyy-MM-dd}\n{day.Tokens.Total:N0} Tokens";
        };
    }
    protected override void OnRender(DrawingContext dc)
    {
        base.OnRender(dc); if (Days.Count == 0 || ActualWidth <= 56) return;
        Brush B(string name) => (Brush)FindResource(name + "Brush");
        void Label(string s, double x, double y) => dc.DrawText(new FormattedText(s, CultureInfo.CurrentUICulture, FlowDirection.LeftToRight, new Typeface("Segoe UI"), 10, B("Muted"), VisualTreeHelper.GetDpi(this).PixelsPerDip), new(x, y));
        const double left = 52; var width = ActualWidth - left - 4; var height = Math.Max(1, ActualHeight - 32); var max = Math.Max(1, Days.Max(d => d.Tokens.Total));
        for (var i = 0; i <= 3; i++) { var y = height * i / 3; dc.DrawLine(new Pen(B("Line"), 1), new(left, y), new(ActualWidth, y)); Label(TokenStatsView.Compact(max * (3 - i) / 3), 0, Math.Max(0, y - 5)); }
        var step = width / Days.Count;
        for (var i = 0; i < Days.Count; i++)
        {
            var h = height * Days[i].Tokens.Total / max; var barWidth = Math.Max(0.2, step * 0.68);
            dc.DrawRoundedRectangle(B("Accent"), null, new(left + i * step + step * 0.16, height - h, barWidth, h), Math.Min(3, barWidth / 2), 3);
            if (i % Math.Max(1, (int)Math.Ceiling(Days.Count / 6d)) == 0) Label(Days[i].Date.ToString("MM/dd", CultureInfo.InvariantCulture), left + i * step, height + 10);
        }
    }
}
