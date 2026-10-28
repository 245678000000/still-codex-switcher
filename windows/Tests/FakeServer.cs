using System.Text.Json;

namespace Still.Tests;
// Only part of the test console executable, never linked into the shipped GUI.
static class FakeServer
{
    public static async Task<int> Run()
    {
        var home = Environment.GetEnvironmentVariable("CODEX_HOME")!;
        if (Path.GetFullPath(Environment.CurrentDirectory) != Path.GetFullPath(home) || File.Exists(Path.Combine(home, "auth.json"))) return 2;
        var mode = File.ReadAllText(Path.Combine(home, ".fixture-mode"));
        // Windows deletion fails if the child outlives disposal and still holds this handle.
        using var handle = new FileStream(Path.Combine(home, ".fixture-live"), FileMode.Create, FileAccess.ReadWrite, FileShare.None);
        for (var i = 0; i < 20; i++) await Console.Error.WriteAsync(new string('x', 4096));
        if (mode == "hang") { await Task.Delay(Timeout.Infinite); return 3; }
        if (mode == "oversize") { await Console.Out.WriteLineAsync(new string('x', 2_000_001)); await Console.Out.FlushAsync(); return 0; }
        while (await Console.In.ReadLineAsync() is { } line)
        {
            using var doc = JsonDocument.Parse(line); var f = doc.RootElement;
            if (!f.TryGetProperty("id", out var id)) continue;
            var n = id.GetInt32(); var now = DateTimeOffset.UtcNow;
            object result = n switch
            {
                2 => new { type = "chatgptAuthTokens" },
                3 or 7 => new { rateLimits = new { limitId = "codex", primary = new { usedPercent = 0, windowDurationMins = 300, resetsAt = now.AddHours(5).ToUnixTimeSeconds() }, secondary = new { usedPercent = 20, windowDurationMins = 10080, resetsAt = now.AddDays(2).ToUnixTimeSeconds() } } },
                4 => new { data = new[] { new { model = Core.WarmupPolicy.Model, hidden = false, supportedReasoningEfforts = new[] { new { reasoningEffort = "low" } } } } },
                5 => new { thread = new { id = "pipe-thread", ephemeral = true }, model = Core.WarmupPolicy.Model, modelProvider = "openai", cwd = home, approvalPolicy = "never", sandbox = new { type = "readOnly" } },
                6 => new { turn = new { id = "pipe-turn" } },
                _ => new { }
            };
            if (mode == "reset" && n == 3)
            {
                if (f.GetProperty("method").GetString() != "account/rateLimitResetCredit/consume" ||
                    f.GetProperty("params").GetProperty("idempotencyKey").GetString() != "00000000-0000-4000-8000-000000000123" ||
                    f.GetProperty("params").GetProperty("creditId").GetString() != "fixture-card" ||
                    Environment.GetEnvironmentVariable("HOME") != home) return 9;
                result = new { outcome = "alreadyRedeemed" };
            }
            if (n == 6)
                await Console.Out.WriteLineAsync(JsonSerializer.Serialize(new { method = "turn/completed", @params = new { threadId = "pipe-thread", turn = new { id = "pipe-turn", status = "completed" } } }));
            await Console.Out.WriteLineAsync(JsonSerializer.Serialize(new { id = n, result }));
            await Console.Out.FlushAsync();
        }
        return 0;
    }
}
