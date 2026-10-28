using Still.Core;

namespace Still.Tests;
static class ProcessTests
{
    public static async Task<bool> Run(Action<string> log)
    {
        var root = Path.Combine(OperatingSystem.IsMacOS() ? "/private/tmp" : Path.GetTempPath(), "still-pipe-fixtures-" + Guid.NewGuid());
        var executable = Environment.ProcessPath!;
        var dotnetHost = Path.GetFileNameWithoutExtension(executable).Equals("dotnet", StringComparison.OrdinalIgnoreCase);
        try
        {
            var auth = TestSuite.Fixture(); var key = Identity.Read(auth).Key;
            var broker = new WarmupBroker(executable, root);
            IWarmupTransport Child(string dir, string mode)
            {
                File.WriteAllText(Path.Combine(dir, ".fixture-mode"), mode);
                var start = QuotaProcess.CreateStartInfo(executable, dir);
                if (dotnetHost) start.ArgumentList.Insert(0, typeof(ProcessTests).Assembly.Location);
                return new QuotaProcess(start);
            }
            var result = await broker.RunAsync(auth, key, CancellationToken.None, dir => Child(dir, "success"));
            if (!result.Sent) throw new Exception("success exchange");
            log("PASS pipe fixture: real child stdin/stdout, early completion, stderr drain and isolated HOME");
            foreach (var mode in new[] { "hang", "oversize" })
            {
                bool rejected = false;
                try { await broker.RunAsync(auth, key, CancellationToken.None, dir => Child(dir, mode), TimeSpan.FromSeconds(3)); }
                catch (UserError) { rejected = true; }
                if (!rejected) throw new Exception(mode);
                log("PASS pipe fixture: " + mode + " child stopped");
            }
            using var cancel = new CancellationTokenSource(TimeSpan.FromSeconds(1));
            bool cancelled = false;
            try { await broker.RunAsync(auth, key, cancel.Token, dir => Child(dir, "hang")); }
            catch (OperationCanceledException) { cancelled = true; }
            if (!cancelled) throw new Exception("cancel");
            log("PASS pipe fixture: caller cancellation stops child");
            if (Directory.EnumerateDirectories(Path.Combine(root, "warmup-requests")).Any()) throw new Exception("cleanup");
            log("PASS pipe fixture: every private directory removed after process disposal");
            var attempt = new ResetAttempt("00000000-0000-4000-8000-000000000123", "fixture-card", DateTimeOffset.UtcNow);
            QuotaProcess ResetChild(string dir, string mode)
            {
                File.WriteAllText(Path.Combine(dir, ".fixture-mode"), mode);
                var host = Path.GetFullPath(Path.Combine(System.Runtime.InteropServices.RuntimeEnvironment.GetRuntimeDirectory(), "..", "..", "..", OperatingSystem.IsWindows() ? "dotnet.exe" : "dotnet"));
                var useHost = !string.IsNullOrEmpty(host) && File.Exists(host);
                var start = DiagnosticBroker.CreateStartInfo(useHost ? host! : executable, dir);
                if (dotnetHost || useHost) start.ArgumentList.Insert(0, typeof(ProcessTests).Assembly.Location);
                return new QuotaProcess(start);
            }
            var reset = new ResetBroker(executable, root);
            var resetResult = await reset.RunAsync(auth, key, attempt, CancellationToken.None, dir => ResetChild(dir, "reset"));
            if (resetResult != ResetOutcome.AlreadyRedeemed) throw new Exception("reset response");
            log("PASS reset pipe: selected card, stable key, isolated HOME and explicit already-redeemed result");
            bool resetTimeout = false;
            try { await reset.RunAsync(auth, key, attempt, CancellationToken.None, dir => ResetChild(dir, "hang"), TimeSpan.FromMilliseconds(300)); }
            catch (UserError) { resetTimeout = true; }
            if (!resetTimeout || Directory.EnumerateDirectories(Path.Combine(root, "reset-requests")).Any()) throw new Exception("reset timeout cleanup");
            log("PASS reset pipe: timeout cleans child home without retry");
            log("PIPE RESULT 7 passed, 0 failed. Synthetic child only; no network or live account.");
            return true;
        }
        catch (Exception ex) { log("FAIL pipe fixtures: " + ex.GetType().Name); return false; }
        finally { if (Directory.Exists(root)) Directory.Delete(root, true); }
    }
}
