using System.IO;
using System.Text;
using System.Text.Json;
using Still.Core;
namespace Still.Tests;
public static class TokenUsageTests
{
    static object Meta(string id = "desktop-one", string origin = "Codex Desktop", string? parent = null, string? fork = null)
    {
        var p = new Dictionary<string, object> { ["id"] = id, ["originator"] = origin, ["source"] = "vscode" };
        if (parent != null) p["parent_thread_id"] = parent; if (fork != null) p["forked_from_id"] = fork;
        return new { type = "session_meta", payload = p };
    }
    static object Context(string model = "gpt-fixture") => new { type = "turn_context", payload = new { model } };
    static object Usage(object input, object output, object? cached = null, object? reasoning = null, string date = "2026-10-27T01:00:00.000Z") => new
    {
        type = "event_msg", timestamp = date, payload = new { type = "token_count", info = new { total_token_usage = new { input_tokens = input, cached_input_tokens = cached ?? 0, output_tokens = output, reasoning_output_tokens = reasoning ?? 0 } } }
    };
    static TokenSession Parse(params object[] records) { var p = new TokenLogParser(); foreach (var r in records) p.Consume(JsonSerializer.SerializeToUtf8Bytes(r)); return p.Session; }
    static string Lines(params object[] records) => string.Join("\n", records.Select(r => JsonSerializer.Serialize(r))) + "\n";
    public static void Run(Action<bool, string> check, string root)
    {
        var first = Usage(1000, 100, 600, 40, "2026-10-26T15:59:00Z"); var second = Usage(1800, 180, 1000, 70);
        object[] records = [Meta(), Context(), first, first, Context("gpt-fixture-next"), second];
        var parsed = Parse(records);
        check(parsed.Eligible && parsed.Events.Count == 2, "tokens repeated cumulative notifications deduplicated");
        check(parsed.Events[1].Tokens == new TokenAmounts(800, 400, 80, 30), "tokens cumulative delta");
        check(parsed.Events[1].Model == "gpt-fixture-next", "tokens model change applies to new delta");
        check(parsed.Events.Sum(e => e.Tokens.Total) == 1980, "tokens cache and reasoning not added twice");
        foreach (var m in new[] { Meta(origin: "codex_vscode"), Meta(origin: "codex_exec"), Meta(parent: "parent"), Meta(fork: "parent") }) check(Parse(m, first).Events.Count == 0, "tokens extension CLI fork and subagent excluded");
        check(Parse(Context(), first).Events.Count == 0, "tokens missing origin excluded");
        var sub = new { type = "session_meta", payload = new { id = "sub", originator = "Codex Desktop", source = new { subagent = "fixture" } } };
        check(Parse(sub, first).Events.Count == 0, "tokens structured subagent source excluded");
        var rollback = Parse(Meta(), first, Usage(100, 10), first, second);
        check(rollback.Events.Count == 2 && rollback.Warnings == 1, "tokens counter rollback and replay not double counted");
        check(Parse(Meta(), first, new { type = "event_msg", payload = new { type = "token_count", info = (object?)null } }, second).Events.Count == 2, "tokens null rate update retains baseline");
        foreach (var u in new[] { Usage(-1, 3), Usage(10, 3, 11), Usage(10, 3, reasoning: 4), Usage(true, 3), Usage(0.5, 3), Usage(1e20, 3) }) check(Parse(Meta(), u).Events.Count == 0, "tokens malformed counts excluded");
        var badDate = Parse(Meta(), Usage(100, 10, date: "invalid"), Usage(150, 15));
        check(badDate.Events[0].Tokens.Total == 55 && badDate.Warnings == 1, "tokens missing date not shifted into later day");
        check(Parse(Meta(), Usage(100, 10, date: "2026-10-27T01:00:00")).Events.Count == 0, "tokens ambiguous naive date skipped");
        var message = new { type = "response_item", payload = new { content = "SECRET token_count content" } };
        check(Parse(Meta(), message, first).Events.Count == 1, "tokens message content not interpreted as counters");
        var zone = TimeZoneInfo.CreateCustomTimeZone("fixture-UTC8", TimeSpan.FromHours(8), "fixture", "fixture");
        var now = DateTimeOffset.Parse("2026-10-27T04:00:00Z"); var snapshot = new TokenSnapshot { Sessions = [parsed] };
        var today = snapshot.Summarize(TokenPeriod.Today, now, zone); var week = snapshot.Summarize(TokenPeriod.Week, now, zone);
        check(today.Total.Total == 880 && today.SessionCount == 1, "tokens local midnight splits by delta");
        check(week.Total.Total == 1980 && week.Days.Count == 7 && week.Models.Count == 2, "tokens seven days zero filled with model breakdown");
        check(snapshot.Summarize(TokenPeriod.Month, now, zone).Days.Count == 30, "tokens thirty calendar day range");
        var pacific = TimeZoneInfo.FindSystemTimeZoneById(OperatingSystem.IsWindows() ? "Pacific Standard Time" : "America/Los_Angeles");
        check(new TokenSnapshot().Summarize(TokenPeriod.Week, DateTimeOffset.Parse("2026-11-03T12:00:00Z"), pacific).Days.Count == 7, "tokens DST keeps seven calendar days");
        parsed.Events.Add(new(now.AddSeconds(1), "future", new(999)));
        check(snapshot.Summarize(TokenPeriod.All, now, zone).Total.Total == 1980, "tokens future dates excluded"); parsed.Events.RemoveAt(parsed.Events.Count - 1);
        var csv = TokenCsv.Make(today);
        check(csv.Contains("2026-10-27,800,400,80,30,880") && !csv.Contains("desktop-one") && !csv.Contains("SECRET"), "tokens CSV only dates and numeric totals");
        var sessions = Path.Combine(root, "sessions", "2026", "10", "27"); var archive = Path.Combine(root, "archived_sessions"); Directory.CreateDirectory(sessions); Directory.CreateDirectory(archive);
        var file = Path.Combine(sessions, "desktop.jsonl"); var bytes = Lines(records); File.WriteAllText(file, bytes);
        File.WriteAllText(Path.Combine(archive, "copy.jsonl"), Lines(Meta(), Context(), first));
        File.WriteAllText(Path.Combine(sessions, "cli.jsonl"), Lines(Meta("cli", "codex_exec"), first));
        var scanner = new TokenLogScanner(); var scan = scanner.Scan(root);
        check(scan.ScannedFiles == 3 && scan.ExcludedFiles == 1 && scan.Sessions.Count == 1, "tokens scanner merges archived duplicate ids");
        check(scan.Summarize(TokenPeriod.All, now, zone).Total.Total == 1980, "tokens fuller duplicate selected");
        check(File.ReadAllText(file) == bytes, "tokens source logs remain unchanged");
        check(scanner.Scan(root).Summarize(TokenPeriod.All, now, zone).Total.Total == 1980, "tokens cached refresh idempotent");
        bytes += Lines(Usage(2000, 200, 1100, 75)); File.WriteAllText(file, bytes);
        check(scanner.Scan(root).Summarize(TokenPeriod.All, now, zone).Total.Total == 2200, "tokens growth invalidates cache");
        bytes += JsonSerializer.Serialize(Usage(2200, 220, 1200, 80)); File.WriteAllText(file, bytes);
        var partial = scanner.Scan(root);
        check(partial.Summarize(TokenPeriod.All, now, zone).Total.Total == 2200 && partial.Warnings == 1, "tokens unterminated tail deferred");
        bytes += "\n"; File.WriteAllText(file, bytes);
        check(scanner.Scan(root).Summarize(TokenPeriod.All, now, zone).Total.Total == 2420, "tokens completed tail picked up");
        var huge = Path.Combine(sessions, "huge.jsonl");
        File.WriteAllText(huge, Lines(Meta("large")) + new string('x', 4 * 1024 * 1024 + 1) + "\n" + Lines(Usage(10, 2)));
        var bounded = scanner.Scan(root); check(bounded.Warnings == 1 && bounded.Summarize(TokenPeriod.All, now, zone).Total.Total == 2432, "tokens oversized line skipped without losing following telemetry"); File.Delete(huge);
        if (!OperatingSystem.IsWindows())
        {
            var link = Path.Combine(sessions, "link.jsonl"); File.CreateSymbolicLink(link, file);
            check(scanner.Scan(root).Warnings > 0, "tokens symlink skipped"); File.Delete(link);
        }
        File.Delete(file);
        check(scanner.Scan(root).Summarize(TokenPeriod.All, now, zone).Total.Total == 1100, "tokens deletion evicts stale cache");
        var missing = scanner.Scan(Path.Combine(root, "missing")); check(missing.ScannedFiles == 0 && missing.Sessions.Count == 0 && missing.Warnings == 0, "tokens missing home yields empty state");
        using var cancelled = new CancellationTokenSource(); cancelled.Cancel();
        try { scanner.Scan(root, cancelled.Token); check(false, "tokens scan cancellable"); } catch (OperationCanceledException) { check(true, "tokens scan cancellable"); }
        var demo = TokenSnapshot.Demo(now);
        check(demo.Summarize(TokenPeriod.Today, now, zone).Total.Total == 865400 && demo.Summarize(TokenPeriod.Week, now, zone).Total.Total == 10693430, "tokens shared Mac and Windows demo golden totals");
    }
}
