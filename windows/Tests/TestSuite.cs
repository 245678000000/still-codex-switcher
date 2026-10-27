using System.IO;
using System.Text;
using System.Text.Json;
using Still.Core;

namespace Still.Tests;
public sealed class MemoryVault : IVault
{
    public readonly Dictionary<string, byte[]> Items = [];
    public bool FailWrites;
    public Action? AfterPut;
    public byte[]? Get(string key) => Items.TryGetValue(key, out var data) ? data : null;
    public void Put(string key, byte[] data) { if (FailWrites) throw new IOException("fixture write failure"); Items[key] = data; AfterPut?.Invoke(); }
    public void Remove(string key) => Items.Remove(key);
}
// An intentionally trivial TEST ONLY codec. Production always uses Windows DPAPI.
sealed class FixtureProtector : IProtector
{
    public byte[] Protect(byte[] data) => data.Select(x => (byte)(x ^ 0xA5)).ToArray();
    public byte[] Unprotect(byte[] data) => Protect(data);
}
public static class TestSuite
{
    public static byte[] Fixture(string subject = "fixture-a", string account = "workspace-a", string refresh = "fixture-refresh", string email = "fixture@example.com")
    {
        var claim = new Dictionary<string, object> { ["sub"] = subject, ["email"] = email, ["https://api.openai.com/auth"] = new { chatgpt_account_id = account, chatgpt_plan_type = "plus" } };
        var payload = Convert.ToBase64String(JsonSerializer.SerializeToUtf8Bytes(claim)).TrimEnd('=').Replace('+', '-').Replace('/', '_');
        return JsonSerializer.SerializeToUtf8Bytes(new { auth_mode = "chatgpt", tokens = new { id_token = "e30." + payload + ".fixture-signature", access_token = "fixture-access", refresh_token = refresh, account_id = account } });
    }
    public static async Task<bool> Run(Action<string> log)
    {
        int pass = 0, fail = 0;
        void Check(bool v, string name) { if (v) { pass++; log("PASS " + name); } else { fail++; log("FAIL " + name); } }
        void Reject(Action action, string name) { try { action(); Check(false, name); } catch { Check(true, name); } }
        async Task RejectAsync(Func<Task> action, string name) { try { await action(); Check(false, name); } catch { Check(true, name); } }
        var tempBase = OperatingSystem.IsMacOS() ? "/private/tmp" : Path.GetTempPath();
        var root = Path.Combine(tempBase, "still-core-tests-" + Guid.NewGuid()); Directory.CreateDirectory(root);
        try
        {
            TokenUsageTests.Run(Check, Path.Combine(root, "token-fixtures"));
            await QuotaTests.Run(Check);
            var a = Fixture(); var b = Fixture("fixture-b", "workspace-b");
            var ia = Identity.Read(a); var ib = Identity.Read(b);
            Check(ia.Email == "fixture@example.com" && ia.Plan == "plus", "identity metadata");
            Check(ia.Key != ib.Key, "distinct users");
            Check(ia.Key != Identity.Read(Fixture(account: "another-workspace")).Key, "distinct workspaces");
            Check(ia.Key == Identity.Read(Fixture(refresh: "fresh-fixture")).Key, "stable identity after refresh");
            Reject(() => Identity.Read("{}"u8.ToArray()), "missing token rejected");
            Reject(() => Identity.Read("bad"u8.ToArray()), "malformed JSON rejected");
            Reject(() => Identity.Read("{\"OPENAI_API_KEY\":\"test\"}"u8.ToArray()), "API key rejected");
            Reject(() => Identity.Read(Fixture(subject: "")), "empty identity rejected");
            Reject(() => Identity.Read(Fixture(refresh: "")), "empty refresh rejected");
            Reject(() => Identity.Read(new byte[2_000_001]), "oversize rejected");
            var paths = new Paths(Path.Combine(root, "data"), Path.Combine(root, "codex"));
            Check(SafeFiles.Read(paths.Auth) == null, "missing auth handled");
            SafeFiles.Write(paths.Auth, a); Check(SafeFiles.Same(SafeFiles.Read(paths.Auth), a), "atomic initial write");
            SafeFiles.Write(paths.Auth, b); Check(SafeFiles.Same(SafeFiles.Read(paths.Auth), b), "atomic replacement");
            Check(!Directory.GetFiles(paths.CodexHome).Any(p => Path.GetFileName(p).StartsWith(".still-")), "temporary file cleanup");
            Reject(() => SafeFiles.Write(paths.Auth, a, (_, _) => throw new IOException("fixture ACL failure")), "ACL failure blocks plaintext write");
            Check(SafeFiles.Same(SafeFiles.Read(paths.Auth), b), "ACL failure preserves current");
            if (!OperatingSystem.IsWindows())
            {
                var link = Path.Combine(root, "link.json"); File.CreateSymbolicLink(link, paths.Auth);
                Reject(() => SafeFiles.Read(link), "symlink read rejected");
                Reject(() => SafeFiles.Write(link, a), "symlink write rejected");
                var dirLink = Path.Combine(root, "linked-directory"); Directory.CreateSymbolicLink(dirLink, paths.CodexHome);
                Reject(() => SafeFiles.Read(Path.Combine(dirLink, "auth.json")), "linked parent rejected");
            }
            ConfigGuard.Check(paths.Config); Check(true, "default file mode");
            SafeFiles.Write(paths.Config, Encoding.UTF8.GetBytes("cli_auth_credentials_store = \"file\" # comment\n[profile]\na=1"));
            ConfigGuard.Check(paths.Config); Check(true, "explicit file mode");
            SafeFiles.Write(paths.Config, Encoding.UTF8.GetBytes("'cli_auth_credentials_store' = 'file'"));
            ConfigGuard.Check(paths.Config); Check(true, "quoted file mode key");
            foreach (var mode in new[] { "keyring", "auto", "ephemeral" })
            {
                var config = Encoding.UTF8.GetBytes("cli_auth_credentials_store = \"" + mode + "\""); SafeFiles.Write(paths.Config, config);
                Reject(() => ConfigGuard.Check(paths.Config), mode + " mode not changed");
                Check(SafeFiles.Same(SafeFiles.Read(paths.Config), config), mode + " config preserved");
            }
            SafeFiles.Write(paths.Config, Encoding.UTF8.GetBytes("\uFEFFcli_auth_credentials_store = \"keyring\""));
            Reject(() => ConfigGuard.Check(paths.Config), "BOM config mode checked");
            var vault = new MemoryVault(); var store = new AccountStore(paths, vault);
            var library = store.Load(); Check(library.Accounts.Count == 0, "new empty library");
            library = store.Capture(library, a); var id = library.Accounts[0].Id;
            Check(library.Accounts.Count == 1 && SafeFiles.Same(vault.Get(id.ToString()), a), "capture credentials");
            library = store.Capture(library, a); Check(library.Accounts.Count == 1 && library.Accounts[0].Id == id, "deduplicate capture");
            var fresh = Fixture(refresh: "new-fixture-token"); library = store.Capture(library, fresh);
            Check(SafeFiles.Same(vault.Get(id.ToString()), fresh), "latest refresh saved");
            var json = Encoding.UTF8.GetString(SafeFiles.Read(paths.Metadata)!);
            Check(!json.Contains("access_token") && !json.Contains("refresh_token") && !json.Contains("fixture-access"), "metadata has no credentials");
            library = store.Capture(library, b); Check(library.Accounts.Count == 2, "second account added");
            library = store.Rename(library, id, " 工作 "); Check(library.Accounts[0].Label == "工作", "rename trims whitespace");
            Reject(() => store.Rename(library, id, " "), "blank note rejected");
            Reject(() => store.Rename(library, id, new string('x', 41)), "oversize note rejected");
            Check(store.Load().Accounts[0].Label == "工作", "library survives reopen");
            library = store.Remove(library, id); Check(library.Accounts.Count == 1 && vault.Get(id.ToString()) == null, "remove saved record");
            Check(SafeFiles.Same(SafeFiles.Read(paths.Auth), b), "remove leaves current file");
            var metadataBefore = SafeFiles.Read(paths.Metadata); vault.FailWrites = true;
            Reject(() => store.Capture(library, a), "vault failure blocks capture");
            Check(SafeFiles.Same(SafeFiles.Read(paths.Metadata), metadataBefore), "vault failure preserves metadata"); vault.FailWrites = false;
            var duplicate = library.Clone(); duplicate.Accounts.Add(duplicate.Accounts[0]); store.Save(duplicate);
            Reject(() => store.Load(), "duplicate IDs rejected");
            var duplicateIdentity = library.Clone(); duplicateIdentity.Accounts.Add(duplicateIdentity.Accounts[0] with { Id = Guid.NewGuid() }); store.Save(duplicateIdentity);
            Reject(() => store.Load(), "duplicate identities rejected");
            SafeFiles.Write(paths.Metadata, "broken"u8.ToArray()); Reject(() => store.Load(), "corrupt metadata rejected");
            Check(Encoding.UTF8.GetString(SafeFiles.Read(paths.Metadata)!) == "broken", "corrupt metadata preserved");
            using (var gate = new OperationLock(paths.Root)) Reject(() => { using var second = new OperationLock(paths.Root); }, "concurrent operation blocked");
            using (var gate = new OperationLock(paths.Root)) Check(true, "operation lock released");
            var txn = new SwitchTransaction(paths.Auth, vault);
            SafeFiles.Write(paths.Auth, a); var started = false;
            await txn.ReplaceAsync(b, () => { started = true; return Task.CompletedTask; });
            Check(started && SafeFiles.Same(SafeFiles.Read(paths.Auth), b), "switch and launch fixture");
            var rollback = JsonSerializer.Deserialize<Rollback>(vault.Get("rollback")!);
            Check(SafeFiles.Same(rollback?.Original, a), "durable rollback before switch");
            SafeFiles.Write(paths.Auth, a);
            await RejectAsync(() => txn.ReplaceAsync(b, () => throw new IOException("fixture launch")), "launch failure reported");
            Check(SafeFiles.Same(SafeFiles.Read(paths.Auth), a), "launch failure restores original");
            vault.FailWrites = true; await RejectAsync(() => txn.ReplaceAsync(b, () => Task.CompletedTask), "backup failure blocks switch"); vault.FailWrites = false;
            Check(SafeFiles.Same(SafeFiles.Read(paths.Auth), a), "backup failure preserves original");
            await RejectAsync(() => txn.ReplaceAsync("bad"u8.ToArray(), () => Task.CompletedTask), "invalid target rejected");
            Check(SafeFiles.Same(SafeFiles.Read(paths.Auth), a), "invalid target leaves current");
            var external = Fixture("fixture-external", "external-workspace");
            await RejectAsync(() => txn.ReplaceAsync(b, () => { SafeFiles.Write(paths.Auth, external); throw new IOException("fixture conflict"); }), "external modification reported");
            Check(SafeFiles.Same(SafeFiles.Read(paths.Auth), external), "external modification preserved");
            SafeFiles.Write(paths.Auth, a); vault.AfterPut = () => SafeFiles.Write(paths.Auth, external);
            await RejectAsync(() => txn.ReplaceAsync(b, () => Task.CompletedTask), "backup race detected"); vault.AfterPut = null;
            Check(SafeFiles.Same(SafeFiles.Read(paths.Auth), external), "backup race preserved");
            File.Delete(paths.Auth); await RejectAsync(() => txn.ReplaceAsync(b, () => throw new IOException("fixture launch")), "empty-original launch failure");
            Check(SafeFiles.Read(paths.Auth) == null, "empty original restored");
            var encrypted = new EncryptedVault(Path.Combine(root, "fixture-vault"), new FixtureProtector()); var key = Guid.NewGuid().ToString();
            encrypted.Put(key, a); Check(SafeFiles.Same(encrypted.Get(key), a), "pluggable vault roundtrip");
            Check(!SafeFiles.Same(SafeFiles.Read(Path.Combine(root, "fixture-vault", key + ".bin")), a), "vault passes data through protector");
            Reject(() => encrypted.Put("../../outside", a), "vault traversal rejected");
            encrypted.Remove(key); Check(encrypted.Get(key) == null, "vault removal");
            foreach (var url in new[] { "https://auth.openai.com/authorize", "https://chatgpt.com/login", "https://auth.chatgpt.com/" }) Check(LoginBroker.ValidUrl(url), "official OAuth host accepted");
            foreach (var url in new[] { "http://auth.openai.com", "https://openai.com.evil.test", "https://evilopenai.com", "https://foo@openai.com", "file:///auth" }) Check(!LoginBroker.ValidUrl(url), "nonofficial OAuth URL rejected");
        }
        catch (Exception ex) { fail++; log("FAIL unexpected: " + ex.GetType().Name + ": " + ex.Message); }
        finally { Directory.Delete(root, true); }
        log($"RESULT {pass} passed, {fail} failed. Synthetic fixtures only; no live account read or changed."); return fail == 0;
    }
}
