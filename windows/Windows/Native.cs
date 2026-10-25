using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Security.AccessControl;
using System.Security.Cryptography;
using System.Security.Principal;
using System.Text.Json;
using Still.Core;

namespace Still.Windows;
public static class PrivateAccess
{
    public static void Set(string path, bool directory)
    {
        SafeFiles.CheckPath(path);
        var sid = WindowsIdentity.GetCurrent().User ?? throw new UserError("读取 Windows 用户身份失败。");
        var system = new SecurityIdentifier(WellKnownSidType.LocalSystemSid, null);
        if (directory)
        {
            var acl = new DirectorySecurity(); acl.SetOwner(sid); acl.SetAccessRuleProtection(true, false);
            foreach (var who in new[] { sid, system }) acl.AddAccessRule(new FileSystemAccessRule(who, FileSystemRights.FullControl, InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit, PropagationFlags.None, AccessControlType.Allow));
            new DirectoryInfo(path).SetAccessControl(acl);
        }
        else
        {
            var acl = new FileSecurity(); acl.SetOwner(sid); acl.SetAccessRuleProtection(true, false);
            foreach (var who in new[] { sid, system }) acl.AddAccessRule(new FileSystemAccessRule(who, FileSystemRights.FullControl, AccessControlType.Allow));
            new FileInfo(path).SetAccessControl(acl);
        }
    }
}
public sealed class WindowsProtector : IProtector
{
    [StructLayout(LayoutKind.Sequential)] struct Blob { public int Length; public IntPtr Data; }
    [DllImport("crypt32.dll", SetLastError = true, CharSet = CharSet.Unicode, ExactSpelling = true)]
    [return: MarshalAs(UnmanagedType.Bool)] static extern bool CryptProtectData(ref Blob data, string? description, IntPtr entropy, IntPtr reserved, IntPtr prompt, uint flags, out Blob result);
    [DllImport("crypt32.dll", SetLastError = true, ExactSpelling = true)]
    [return: MarshalAs(UnmanagedType.Bool)] static extern bool CryptUnprotectData(ref Blob data, IntPtr description, IntPtr entropy, IntPtr reserved, IntPtr prompt, uint flags, out Blob result);
    [DllImport("kernel32.dll")] static extern IntPtr LocalFree(IntPtr value);
    public byte[] Protect(byte[] plain) => Transform(plain, true);
    public byte[] Unprotect(byte[] encrypted) => Transform(encrypted, false);
    static byte[] Transform(byte[] data, bool protect)
    {
        var input = new Blob { Length = data.Length, Data = Marshal.AllocHGlobal(data.Length) }; Blob output = default;
        try
        {
            Marshal.Copy(data, 0, input.Data, data.Length);
            // CRYPTPROTECT_UI_FORBIDDEN only. No LOCAL_MACHINE flag: bound to current user.
            var ok = protect ? CryptProtectData(ref input, "Still Codex account", IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, 1, out output) : CryptUnprotectData(ref input, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, 1, out output);
            if (!ok) throw new UserError("Windows 凭据加密操作未完成。请使用保存账号时的 Windows 用户与设备，不要直接复制账号库到另一台电脑。");
            var result = new byte[output.Length]; Marshal.Copy(output.Data, result, 0, result.Length); return result;
        }
        finally
        {
            for (var i = 0; i < input.Length; i++) Marshal.WriteByte(input.Data, i, 0);
            Marshal.FreeHGlobal(input.Data);
            if (output.Data != IntPtr.Zero) { for (var i = 0; i < output.Length; i++) Marshal.WriteByte(output.Data, i, 0); LocalFree(output.Data); }
        }
    }
}
public sealed record DesktopTarget(string Exe, string? AppId = null)
{
    public string Version { get { try { return FileVersionInfo.GetVersionInfo(Exe).ProductVersion ?? "Windows"; } catch { return "Windows"; } } }
    public static bool LooksOfficial(string exe)
    {
        try
        {
            if (!File.Exists(exe) || !new[] { "codex.exe", "chatgpt.exe" }.Contains(Path.GetFileName(exe).ToLowerInvariant())) return false;
            var v = FileVersionInfo.GetVersionInfo(exe);
            return (v.CompanyName ?? "").Contains("OpenAI", StringComparison.OrdinalIgnoreCase) && ((v.ProductName ?? "").Contains("Codex", StringComparison.OrdinalIgnoreCase) || (v.ProductName ?? "").Contains("ChatGPT", StringComparison.OrdinalIgnoreCase));
        }
        catch { return false; }
    }
    public static async Task<DesktopTarget?> DiscoverAsync(string? configured)
    {
        DesktopTarget? candidate = !string.IsNullOrWhiteSpace(configured) && LooksOfficial(configured) ? new(configured) : null;
        foreach (var p in Process.GetProcesses())
        {
            using (p) { try { if (p.ProcessName is not ("Codex" or "ChatGPT" or "codex")) continue; var exe = p.MainModule?.FileName; if (candidate == null && exe != null && LooksOfficial(exe)) candidate = new(exe); } catch { } }
        }
        // Read-only MSIX inventory. No downloads, installs, profile scripts or policy changes.
        try
        {
            var ps = new ProcessStartInfo(Path.Combine(Environment.SystemDirectory, "WindowsPowerShell/v1.0/powershell.exe")) { UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true };
            foreach (var arg in new[] { "-NoProfile", "-NonInteractive", "-Command", "$ErrorActionPreference='Stop'; [Console]::OutputEncoding=[Text.UTF8Encoding]::new(); ConvertTo-Json -Compress -InputObject @(Get-AppxPackage -Name 'OpenAI.Codex' | ForEach-Object { $p=$_; $m=Get-AppxPackageManifest $p; $m.Package.Applications.Application | ForEach-Object { [PSCustomObject]@{ Exe=(Join-Path $p.InstallLocation $_.Executable); AppId=($p.PackageFamilyName+'!'+$_.Id) } } })" }) ps.ArgumentList.Add(arg);
            using var proc = Process.Start(ps)!;
            var stdout = proc.StandardOutput.ReadToEndAsync(); var stderr = proc.StandardError.ReadToEndAsync();
            using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(12));
            try { await proc.WaitForExitAsync(timeout.Token); } catch (OperationCanceledException) { if (!proc.HasExited) proc.Kill(); return candidate; }
            var text = await stdout; _ = await stderr;
            if (proc.ExitCode == 0 && !string.IsNullOrWhiteSpace(text))
                foreach (var item in JsonSerializer.Deserialize<List<DesktopTarget>>(text) ?? [])
                    if (LooksOfficial(item.Exe) && (candidate == null || item.Exe.Equals(candidate.Exe, StringComparison.OrdinalIgnoreCase))) return item;
        }
        catch { }
        if (candidate != null) return candidate;
        foreach (var folder in new[] { Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles) })
            foreach (var rel in new[] { "Programs/Codex/Codex.exe", "Codex/Codex.exe", "Programs/ChatGPT/ChatGPT.exe" })
            { var path = Path.Combine(folder, rel.Replace('/', Path.DirectorySeparatorChar)); if (LooksOfficial(path)) return new(path); }
        return null;
    }
    public string? FindCli(string? configured)
    {
        if (!string.IsNullOrEmpty(configured) && File.Exists(configured) && Path.GetFileName(configured).Equals("codex.exe", StringComparison.OrdinalIgnoreCase) && !Path.GetFullPath(configured).Equals(Path.GetFullPath(Exe), StringComparison.OrdinalIgnoreCase)) return configured;
        var root = Path.GetDirectoryName(Exe)!;
        foreach (var rel in new[] { "resources/codex.exe", "resources/codex-cli/codex.exe", "resources/codex-cli/x86_64-pc-windows-msvc/codex.exe", "resources/codex-cli/bin/codex.exe" })
        { var p = Path.Combine(root, rel.Replace('/', Path.DirectorySeparatorChar)); if (File.Exists(p)) return p; }
        try { return Directory.EnumerateFiles(Path.Combine(root, "resources"), "codex.exe", new EnumerationOptions { RecurseSubdirectories = true, MaxRecursionDepth = 5, IgnoreInaccessible = true }).FirstOrDefault(); }
        catch { return null; }
    }
    bool Belongs(Process p)
    {
        var path = p.MainModule?.FileName;
        var root = Path.GetDirectoryName(Exe)! + Path.DirectorySeparatorChar;
        return path != null && path.StartsWith(root, StringComparison.OrdinalIgnoreCase);
    }
    public async Task QuitAsync(IProgress<string> progress)
    {
        var name = Path.GetFileNameWithoutExtension(Exe);
        foreach (var p in Process.GetProcessesByName(name))
        {
            using (p)
            {
                try
                {
                    if (!string.Equals(p.MainModule?.FileName, Exe, StringComparison.OrdinalIgnoreCase)) continue;
                    if (p.MainWindowHandle != IntPtr.Zero) p.CloseMainWindow();
                }
                catch (Win32Exception) { throw new UserError("访问 Codex 进程受限。请手动退出 Codex 后再试；切换器无需管理员权限。"); }
            }
        }
        progress.Report("等待 Codex 完全退出；如缩到托盘，请从 Codex 菜单退出…");
        for (var attempt = 0; attempt < 120; attempt++)
        {
            bool live = false;
            foreach (var p in Process.GetProcesses())
            {
                using (p)
                {
                    try { if (Belongs(p)) live = true; }
                    catch (Win32Exception) { if (p.ProcessName.Equals(name, StringComparison.OrdinalIgnoreCase) || p.ProcessName.Equals("codex", StringComparison.OrdinalIgnoreCase)) live = true; }
                    catch (InvalidOperationException) { }
                }
            }
            if (!live) return; await Task.Delay(250);
        }
        throw new UserError("Codex 或其后台组件仍在运行，登录文件保持原样。请从 Codex 菜单完整退出后重试。");
    }
    public Task LaunchAsync()
    {
        if (!LooksOfficial(Exe)) throw new UserError("Codex 程序路径已变化，请在设置里重新检测或选择。");
        if (!string.IsNullOrEmpty(AppId))
        {
            // Use the package identity, not direct execution of a WindowsApps binary.
            var manager = (IActivationManager)new ActivationManager();
            try { Marshal.ThrowExceptionForHR(manager.ActivateApplication(AppId, null, 0, out _)); }
            finally { Marshal.FinalReleaseComObject(manager); }
        }
        else
        {
            using var child = Process.Start(new ProcessStartInfo(Exe) { UseShellExecute = true });
            if (child == null) throw new UserError("系统未返回 Codex 启动进程，请手动打开后核对。");
        }
        // OS activation success is not proof of server-side login. Never roll back merely
        // because a process lookup was delayed or denied after activation succeeded.
        return Task.CompletedTask;
    }
    [ComImport, Guid("45BA127D-10A8-46EA-8AB7-56EA9078943C")]
    class ActivationManager { }
    [ComImport, Guid("2E941141-7F97-4756-BA1D-9DECDE894A3D"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IActivationManager
    {
        [PreserveSig] int ActivateApplication([MarshalAs(UnmanagedType.LPWStr)] string id, [MarshalAs(UnmanagedType.LPWStr)] string? arguments, uint options, out uint processId);
    }
}
