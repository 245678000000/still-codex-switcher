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
            if (render >= 0 && render + 1 < e.Args.Length)
            {
                await window.Dispatcher.InvokeAsync(() => { }, System.Windows.Threading.DispatcherPriority.ApplicationIdle);
                window.UpdateLayout();
                var bitmap = new System.Windows.Media.Imaging.RenderTargetBitmap((int)window.ActualWidth, (int)window.ActualHeight, 96, 96, System.Windows.Media.PixelFormats.Pbgra32);
                bitmap.Render(window);
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
