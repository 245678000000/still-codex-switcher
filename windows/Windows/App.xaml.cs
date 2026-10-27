using System.IO;
using System.Windows;
using Still.Core;

namespace Still.Windows;
public partial class App : Application
{
    protected override async void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        if (e.Args.Contains("--self-test"))
        {
            var log = new List<string>(); var ok = await Tests.TestSuite.Run(log.Add);
            string? temp = null;
            try
            {
                temp = Path.Combine(Path.GetTempPath(), "still-windows-test-" + Guid.NewGuid()); Directory.CreateDirectory(temp); PrivateAccess.Set(temp, true);
                var vault = new EncryptedVault(Path.Combine(temp, "vault"), new WindowsProtector(), PrivateAccess.Set);
                var key = Guid.NewGuid().ToString(); var data = Tests.TestSuite.Fixture(); vault.Put(key, data);
                if (!SafeFiles.Same(vault.Get(key), data)) throw new Exception("DPAPI roundtrip"); log.Add("PASS Windows DPAPI roundtrip");
                if (SafeFiles.Same(File.ReadAllBytes(Path.Combine(temp, "vault", key + ".bin")), data)) throw new Exception("ciphertext differs"); log.Add("PASS encrypted on disk");
                var acl = new FileInfo(Path.Combine(temp, "vault", key + ".bin")).GetAccessControl();
                if (!acl.AreAccessRulesProtected) throw new Exception("ACL protection"); log.Add("PASS protected file ACL");
                vault.Remove(key); if (vault.Get(key) != null) throw new Exception("vault cleanup"); log.Add("PASS Windows vault cleanup");
            }
            catch (Exception ex) { ok = false; log.Add("FAIL Windows native fixture: " + ex.GetType().Name); }
            finally { if (temp != null && Directory.Exists(temp)) Directory.Delete(temp, true); }
            var index = Array.IndexOf(e.Args, "--test-output");
            var output = index >= 0 && index + 1 < e.Args.Length ? e.Args[index + 1] : Path.Combine(Path.GetTempPath(), "StillCodexSwitcher-tests.txt");
            await File.WriteAllLinesAsync(output, log); Shutdown(ok ? 0 : 1); return;
        }
        try
        {
            var render = Array.IndexOf(e.Args, "--render");
            var window = new MainWindow(e.Args.Contains("--demo") || render >= 0); MainWindow = window;
            if (e.Args.Contains("--dark")) window.SetDemoTheme("dark");
            window.Show();
            if (e.Args.Contains("--render-tokens"))
            {
                window.ShowDemoTokens(e.Args.Contains("--tokens-empty"));
                if (!window.CheckDemoTokens()) throw new Exception("Synthetic Token UI check failed");
                window.ShowDemoTokens(e.Args.Contains("--tokens-empty"));
            }
            if (render >= 0 && render + 1 < e.Args.Length)
            {
                await window.Dispatcher.InvokeAsync(() => { }, System.Windows.Threading.DispatcherPriority.ApplicationIdle);
                if (e.Args.Contains("--render-accounts"))
                {
                    window.ShowDemoQuotaList();
                    await window.Dispatcher.InvokeAsync(() => { }, System.Windows.Threading.DispatcherPriority.ApplicationIdle);
                }
                window.UpdateLayout();
                var content = (FrameworkElement)window.Content;
                if (e.Args.Contains("--render-tokens"))
                {
                    var size = e.Args.Contains("--compact") ? new Size(940, 680) : new Size(1100, 1430);
                    // Detach from the desktop-sized HWND before measuring. Otherwise WPF's
                    // layout pass clamps the fixture to the runner screen and hides lower cards.
                    window.Content = null;
                    content.Width = size.Width; content.Height = size.Height;
                    content.Measure(size); content.Arrange(new Rect(size)); content.UpdateLayout();
                }
                var bounds = new Rect(0, 0, content.ActualWidth, content.ActualHeight);
                var visual = new System.Windows.Media.DrawingVisual();
                using (var drawing = visual.RenderOpen())
                {
                    drawing.DrawRectangle((System.Windows.Media.Brush)FindResource("BackgroundBrush"), null, bounds);
                    drawing.DrawRectangle(new System.Windows.Media.VisualBrush(content) { ViewboxUnits = System.Windows.Media.BrushMappingMode.Absolute, Viewbox = bounds, Stretch = System.Windows.Media.Stretch.Fill }, null, bounds);
                }
                var bitmap = new System.Windows.Media.Imaging.RenderTargetBitmap((int)Math.Ceiling(bounds.Width), (int)Math.Ceiling(bounds.Height), 96, 96, System.Windows.Media.PixelFormats.Pbgra32);
                bitmap.Render(visual);
                var png = new System.Windows.Media.Imaging.PngBitmapEncoder(); png.Frames.Add(System.Windows.Media.Imaging.BitmapFrame.Create(bitmap));
                using var file = File.Create(e.Args[render + 1]); png.Save(file); Shutdown(0);
            }
        }
        catch (Exception ex)
        {
            var render = Array.IndexOf(e.Args, "--render");
            if (render >= 0 && render + 1 < e.Args.Length)
            {
                // Render mode always uses synthetic accounts. Keep CI headless and diagnosable.
                try { File.WriteAllText(e.Args[render + 1] + ".error.txt", ex.ToString()); } catch { }
            }
            else MessageBox.Show(ex is UserError ? ex.Message : "初始化未完成，请检查本地目录权限或查看使用说明。", "栖言 · Codex 账号");
            Shutdown(1);
        }
    }
}
