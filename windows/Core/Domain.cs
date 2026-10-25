using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace Still.Core;
public sealed class UserError(string message) : Exception(message);
public sealed record Identity(string Key, string Email, string Plan)
{
    public static Identity Read(byte[] data)
    {
        try
        {
            if (data.Length > 2_000_000) throw new FormatException();
            using var doc = JsonDocument.Parse(data);
            var t = doc.RootElement.GetProperty("tokens");
            foreach (var key in new[] { "id_token", "access_token", "refresh_token" })
                if (string.IsNullOrWhiteSpace(t.GetProperty(key).GetString())) throw new FormatException();
            var parts = t.GetProperty("id_token").GetString()!.Split('.');
            if (parts.Length != 3) throw new FormatException();
            var payload = parts[1].Replace('-', '+').Replace('_', '/');
            payload = payload.PadRight((payload.Length + 3) / 4 * 4, '=');
            using var claims = JsonDocument.Parse(Convert.FromBase64String(payload));
            var c = claims.RootElement;
            var subject = c.GetProperty("sub").GetString();
            var a = c.TryGetProperty("https://api.openai.com/auth", out var auth) ? auth : default;
            string? Field(JsonElement e, string name) => e.ValueKind == JsonValueKind.Object && e.TryGetProperty(name, out var v) && v.ValueKind == JsonValueKind.String ? v.GetString() : null;
            var account = Field(t, "account_id") ?? Field(a, "chatgpt_account_id");
            if (string.IsNullOrWhiteSpace(subject) || string.IsNullOrWhiteSpace(account)) throw new FormatException();
            // Display metadata only; JWT decoding is not a server-side authentication check.
            var digest = Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(subject + "\0" + account)));
            return new(digest, Field(c, "email") ?? "未显示邮箱", Field(a, "chatgpt_plan_type") ?? "chatgpt");
        }
        catch (Exception e) when (e is JsonException or FormatException or InvalidOperationException or KeyNotFoundException or ArgumentException)
        { throw new UserError("登录资料格式不完整。请通过 ChatGPT 登录 Codex；此版本不切换 API Key 或临时凭据。"); }
    }
}
public sealed record Account(Guid Id, string IdentityKey, string Label, string Email, string Plan, DateTimeOffset SavedAt, int Color);
public sealed class Library
{
    public int Version { get; set; } = 1;
    public List<Account> Accounts { get; set; } = [];
    public string Theme { get; set; } = "system";
    public string? DesktopPath { get; set; }
    public string? CliPath { get; set; }
    public string? CodexHome { get; set; }
    public DateTimeOffset? LastSwitch { get; set; }
    public Library Clone() => JsonSerializer.Deserialize<Library>(JsonSerializer.Serialize(this))!;
}
public sealed record Paths(string Root, string CodexHome)
{
    public string Metadata => Path.Combine(Root, "accounts.json");
    public string Auth => Path.Combine(CodexHome, "auth.json");
    public string Config => Path.Combine(CodexHome, "config.toml");
}
public static class ConfigGuard
{
    public static void Check(string path)
    {
        var data = SafeFiles.Read(path); if (data == null) return;
        var text = Encoding.UTF8.GetString(data);
        foreach (var raw in text.Split('\n'))
        {
            var line = raw.Trim().TrimStart('\uFEFF'); if (line.StartsWith('[')) break;
            if (!Regex.IsMatch(line, "^(?:cli_auth_credentials_store|[\"']cli_auth_credentials_store[\"'])\\s*=")) continue;
            if (!Regex.IsMatch(line, "^(?:cli_auth_credentials_store|[\"']cli_auth_credentials_store[\"'])\\s*=\\s*[\"']file[\"']\\s*(#.*)?$"))
                throw new UserError("检测到非 file 登录存储模式。切换器已保留现有配置；请先核对 Codex 的凭据存储设置。");
        }
    }
}
public interface IProtector { byte[] Protect(byte[] plain); byte[] Unprotect(byte[] encrypted); }
public interface IVault { byte[]? Get(string key); void Put(string key, byte[] value); void Remove(string key); }
public sealed class EncryptedVault(string root, IProtector protector, Action<string, bool>? secure = null) : IVault
{
    string FileFor(string key)
    {
        if (key != "rollback" && !Guid.TryParseExact(key, "D", out _)) throw new UserError("凭据标识无效。");
        return Path.Combine(root, key + ".bin");
    }
    public byte[]? Get(string key) { var data = SafeFiles.Read(FileFor(key)); return data == null ? null : protector.Unprotect(data); }
    public void Put(string key, byte[] value) => SafeFiles.Write(FileFor(key), protector.Protect(value), secure);
    public void Remove(string key) { var p = FileFor(key); SafeFiles.CheckPath(p); File.Delete(p); }
}
public static class SafeFiles
{
    public static void CheckPath(string path)
    {
        var full = Path.GetFullPath(path);
        for (var p = full; !string.IsNullOrEmpty(p); p = Path.GetDirectoryName(p))
        {
            try { if ((File.GetAttributes(p) & FileAttributes.ReparsePoint) != 0) throw new UserError("数据路径含符号链接或目录联接，请选本机普通目录。原文件保持不变。"); }
            catch (FileNotFoundException) { }
            catch (DirectoryNotFoundException) { }
        }
    }
    public static byte[]? Read(string path)
    {
        CheckPath(path);
        try
        {
            using var file = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read);
            if (file.Length > 2_000_000) throw new UserError("文件大小超出预期，原文件保持不变。");
            var data = new byte[file.Length]; file.ReadExactly(data); return data;
        }
        catch (FileNotFoundException) { return null; }
        catch (DirectoryNotFoundException) { return null; }
    }
    public static void Write(string path, byte[] data, Action<string, bool>? secure = null)
    {
        CheckPath(path);
        var dir = Path.GetDirectoryName(Path.GetFullPath(path))!;
        if (!Directory.Exists(dir)) { Directory.CreateDirectory(dir); secure?.Invoke(dir, true); }
        var temp = Path.Combine(dir, ".still-" + Guid.NewGuid().ToString("N"));
        try
        {
            using (var f = new FileStream(temp, FileMode.CreateNew, FileAccess.Write, FileShare.None))
            {
                // Restrict access before writing any plaintext credentials.
                secure?.Invoke(temp, false); f.Write(data); f.Flush(true);
            }
            CheckPath(path);
            if (File.Exists(path)) File.Replace(temp, path, null); else File.Move(temp, path);
        }
        finally { if (File.Exists(temp)) File.Delete(temp); }
    }
    public static bool Same(byte[]? a, byte[]? b) => a == null ? b == null : b != null && a.AsSpan().SequenceEqual(b);
    public static Library Load(string path)
    {
        var data = Read(path); if (data == null) return new();
        try
        {
            var lib = JsonSerializer.Deserialize<Library>(data) ?? throw new JsonException();
            if (lib.Version != 1 || lib.Accounts == null || lib.Accounts.Any(a => a == null || a.Id == Guid.Empty || string.IsNullOrEmpty(a.IdentityKey) || a.Label == null) ||
                lib.Accounts.Select(a => a.Id).Distinct().Count() != lib.Accounts.Count || lib.Accounts.Select(a => a.IdentityKey).Distinct().Count() != lib.Accounts.Count)
                throw new JsonException();
            return lib;
        }
        catch (JsonException) { throw new UserError("账号列表损坏或版本不兼容，原文件已保留。请先检查本地数据目录。"); }
    }
    public static void Save(string path, Library lib, Action<string, bool>? secure = null) => Write(path, JsonSerializer.SerializeToUtf8Bytes(lib, new JsonSerializerOptions { WriteIndented = true }), secure);
}
public sealed class OperationLock : IDisposable
{
    readonly FileStream stream;
    public OperationLock(string root)
    {
        SafeFiles.CheckPath(root); Directory.CreateDirectory(root);
        var path = Path.Combine(root, "operation.lock"); SafeFiles.CheckPath(path);
        try { stream = new FileStream(path, FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None); }
        catch (IOException) { throw new UserError("另一个账号管理操作正在进行，请稍后再试。"); }
    }
    public void Dispose() => stream.Dispose();
}
public sealed class AccountStore(Paths paths, IVault vault, Action<string, bool>? secure = null)
{
    // Caller must hold OperationLock across read-modify-write operations.
    public Library Load() => SafeFiles.Load(paths.Metadata);
    public void Save(Library lib) => SafeFiles.Save(paths.Metadata, lib, secure);
    public Library Capture(Library lib, byte[] data)
    {
        var identity = Identity.Read(data); var next = lib.Clone();
        var old = next.Accounts.FirstOrDefault(a => a.IdentityKey == identity.Key);
        var name = identity.Email.Contains('@') ? identity.Email.Split('@')[0] : "我的账号";
        var a = new Account(old?.Id ?? Guid.NewGuid(), identity.Key, old?.Label ?? name, identity.Email, identity.Plan, DateTimeOffset.Now, old?.Color ?? next.Accounts.Count % 4);
        var previous = vault.Get(a.Id.ToString());
        if (old != null) next.Accounts[next.Accounts.IndexOf(old)] = a; else next.Accounts.Add(a);
        vault.Put(a.Id.ToString(), data);
        try { Save(next); }
        catch { if (previous != null) vault.Put(a.Id.ToString(), previous); else vault.Remove(a.Id.ToString()); throw; }
        return next;
    }
    public Library Rename(Library lib, Guid id, string name)
    {
        name = name.Trim(); if (name.Length == 0 || name.Length > 40) throw new UserError("备注请输入 1–40 个字符。");
        var next = lib.Clone(); var i = next.Accounts.FindIndex(a => a.Id == id);
        if (i < 0) throw new UserError("这个账号已被移除，请刷新列表。");
        next.Accounts[i] = next.Accounts[i] with { Label = name }; Save(next); return next;
    }
    public Library Remove(Library lib, Guid id)
    {
        var next = lib.Clone(); next.Accounts.RemoveAll(a => a.Id == id);
        var previous = vault.Get(id.ToString()); vault.Remove(id.ToString());
        try { Save(next); } catch { if (previous != null) vault.Put(id.ToString(), previous); throw; }
        return next;
    }
}
public sealed record Rollback(byte[]? Original, string TargetHash, DateTimeOffset Date);
public sealed class SwitchTransaction(string auth, IVault vault, Action<string, bool>? secure = null)
{
    public async Task ReplaceAsync(byte[] target, Func<Task> launch)
    {
        _ = Identity.Read(target); var original = SafeFiles.Read(auth); if (original != null) _ = Identity.Read(original);
        vault.Put("rollback", JsonSerializer.SerializeToUtf8Bytes(new Rollback(original, Convert.ToHexString(SHA256.HashData(target)), DateTimeOffset.Now)));
        if (!SafeFiles.Same(SafeFiles.Read(auth), original)) throw new UserError("备份期间登录文件被其他程序更新，已保留当前状态。请结束其他 Codex 会话后重试。");
        SafeFiles.Write(auth, target, secure);
        try { await launch(); }
        catch
        {
            if (!SafeFiles.Same(SafeFiles.Read(auth), target)) throw new UserError("启动未完成，登录文件又有变化。已保留其最新状态与回滚备份，请核对账号。");
            if (original == null) File.Delete(auth); else SafeFiles.Write(auth, original, secure);
            throw new UserError("Codex 启动未完成，已恢复原登录文件。请手动打开 Codex。");
        }
    }
}
