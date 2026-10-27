using System.Globalization;
using System.Text;
using System.Text.Json;

namespace Still.Core;

public readonly record struct TokenAmounts(long Input = 0, long Cached = 0, long Output = 0, long Reasoning = 0)
{
    public long Total => Input + Output;
    public static TokenAmounts operator +(TokenAmounts a, TokenAmounts b) => new(a.Input + b.Input, a.Cached + b.Cached, a.Output + b.Output, a.Reasoning + b.Reasoning);
    public TokenAmounts? Delta(TokenAmounts old)
    {
        var d = new TokenAmounts(Input - old.Input, Cached - old.Cached, Output - old.Output, Reasoning - old.Reasoning);
        return d.Input < 0 || d.Cached < 0 || d.Output < 0 || d.Reasoning < 0 || d.Cached > d.Input || d.Reasoning > d.Output ? null : d;
    }
    public static TokenAmounts? Read(JsonElement o)
    {
        if (o.ValueKind != JsonValueKind.Object) return null;
        long? N(string key, bool optional = false)
        {
            if (!o.TryGetProperty(key, out var v)) return optional ? 0 : null;
            return v.ValueKind == JsonValueKind.Number && v.TryGetInt64(out var n) && n is >= 0 and <= 1_000_000_000_000 ? n : null;
        }
        var i = N("input_tokens"); var c = N("cached_input_tokens", true); var output = N("output_tokens"); var r = N("reasoning_output_tokens", true);
        return i.HasValue && c.HasValue && output.HasValue && r.HasValue && c <= i && r <= output ? new(i.Value, c.Value, output.Value, r.Value) : null;
    }
}
public sealed record TokenEvent(DateTimeOffset Date, string Model, TokenAmounts Tokens);
public sealed class TokenSession
{
    public string Id { get; set; } = "";
    public bool Eligible { get; set; }
    public int Warnings { get; set; }
    public List<TokenEvent> Events { get; } = [];
}
public sealed class TokenLogParser
{
    public TokenSession Session { get; } = new();
    bool metadataSeen;
    TokenAmounts previous;
    string model = "未知模型";
    static string? Text(JsonElement o, string key) => o.TryGetProperty(key, out var v) && v.ValueKind == JsonValueKind.String ? v.GetString() : null;
    public void Consume(byte[] bytes)
    {
        // Only three telemetry record types enter JSON parsing. No content or credentials enter the result.
        var span = bytes.AsSpan();
        if (span.IndexOf("\"session_meta\""u8) < 0 && span.IndexOf("\"turn_context\""u8) < 0 && span.IndexOf("\"token_count\""u8) < 0) return;
        try
        {
            using var doc = JsonDocument.Parse(bytes);
            var o = doc.RootElement;
            if (o.ValueKind != JsonValueKind.Object || !o.TryGetProperty("payload", out var p) || p.ValueKind != JsonValueKind.Object) return;
            var type = Text(o, "type");
            if (type == "session_meta")
            {
                if (metadataSeen) return; metadataSeen = true;
                Session.Id = Text(p, "id") ?? Text(p, "session_id") ?? "";
                // The desktop also writes source=vscode. Originator distinguishes it from the extension.
                Session.Eligible = Text(p, "originator") == "Codex Desktop" && Text(p, "source") != null && Session.Id.Length > 0
                    && !p.TryGetProperty("parent_thread_id", out _) && !p.TryGetProperty("forked_from_id", out _);
                return;
            }
            if (!Session.Eligible) return;
            if (type == "turn_context")
            {
                var name = Text(p, "model");
                model = name is { Length: > 0 and <= 80 } && name.All(c => char.IsAsciiLetterOrDigit(c) || "-._/:".Contains(c)) ? name : "未知模型";
                return;
            }
            if (type != "event_msg" || Text(p, "type") != "token_count") return;
            if (!p.TryGetProperty("info", out var info) || info.ValueKind != JsonValueKind.Object) return;
            if (!info.TryGetProperty("total_token_usage", out var usage) || TokenAmounts.Read(usage) is not { } current || current.Delta(previous) is not { } delta)
            { Session.Warnings++; return; }
            previous = current;
            if (delta.Total == 0) return;
            var date = Text(o, "timestamp");
            // Require explicit timezone; local naive timestamps have an ambiguous day boundary.
            if (date == null || !System.Text.RegularExpressions.Regex.IsMatch(date, @"(Z|[+-]\d{2}:\d{2})$")
                || !DateTimeOffset.TryParse(date, CultureInfo.InvariantCulture, DateTimeStyles.None, out var stamp)) { Session.Warnings++; return; }
            Session.Events.Add(new(stamp, model, delta));
        }
        catch (JsonException) { Session.Warnings++; }
    }
}
public enum TokenPeriod { Today, Week, Month, All }
public sealed record TokenDay(DateOnly Date, TokenAmounts Tokens);
public sealed record TokenModel(string Name, TokenAmounts Tokens);
public sealed record TokenSummary(TokenAmounts Total, int SessionCount, IReadOnlyList<TokenDay> Days, IReadOnlyList<TokenModel> Models);
public sealed class TokenSnapshot
{
    public List<TokenSession> Sessions { get; set; } = [];
    public int ScannedFiles { get; set; }
    public int ExcludedFiles { get; set; }
    public int Warnings { get; set; }
    public DateTimeOffset FetchedAt { get; set; } = DateTimeOffset.Now;
    public TokenSummary Summarize(TokenPeriod period, DateTimeOffset? now = null, TimeZoneInfo? zone = null)
    {
        var end = now ?? DateTimeOffset.Now; zone ??= TimeZoneInfo.Local;
        DateOnly Day(DateTimeOffset d) => DateOnly.FromDateTime(TimeZoneInfo.ConvertTime(d, zone).DateTime);
        var today = Day(end); DateOnly? start = period == TokenPeriod.All ? null : today.AddDays(period == TokenPeriod.Today ? 0 : period == TokenPeriod.Week ? -6 : -29);
        TokenAmounts total = new(); var days = new Dictionary<DateOnly, TokenAmounts>(); var models = new Dictionary<string, TokenAmounts>(); var count = 0;
        foreach (var s in Sessions)
        {
            var found = false;
            foreach (var e in s.Events)
            {
                var day = Day(e.Date);
                if (e.Date > end || start is { } first && day < first) continue;
                found = true; total += e.Tokens; days[day] = days.GetValueOrDefault(day) + e.Tokens; models[e.Model] = models.GetValueOrDefault(e.Model) + e.Tokens;
            }
            if (found) count++;
        }
        var beginning = start ?? (days.Count > 0 ? days.Keys.Min() : (DateOnly?)null);
        if (beginning is { } d) for (var i = 0; d <= today && i < 3660; i++, d = d.AddDays(1)) days.TryAdd(d, new());
        return new(total, count, days.OrderBy(x => x.Key).Select(x => new TokenDay(x.Key, x.Value)).ToArray(),
            models.OrderByDescending(x => x.Value.Total).ThenBy(x => x.Key, StringComparer.Ordinal).Select(x => new TokenModel(x.Key, x.Value)).ToArray());
    }
    public static TokenSnapshot Demo(DateTimeOffset? time = null)
    {
        var now = time ?? DateTimeOffset.Now; var session = new TokenSession { Id = "synthetic-desktop", Eligible = true };
        for (var d = 0; d < 30; d++)
        {
            var input = (d % 5 + 2) * 418_500L;
            session.Events.Add(new(now.AddDays(-d), d % 3 == 0 ? "gpt-demo-small" : "gpt-demo", new(input, input / 2, 28_400 + d * 1_530, 12_200)));
        }
        return new() { Sessions = [session], ScannedFiles = 1, FetchedAt = now };
    }
}

public sealed class TokenLogScanner
{
    readonly record struct Stamp(long Size, long Modified, long Created);
    readonly Dictionary<string, (Stamp Stamp, TokenSession Session)> cache = new(StringComparer.Ordinal);
    const long MaxBytes = 512L * 1024 * 1024;
    // Callers serialize scans on one worker; no account/network dependency.
    public TokenSnapshot Scan(string home, CancellationToken cancellation = default)
    {
        var result = new TokenSnapshot(); var files = new List<(string Path, Stamp Stamp)>();
        void Walk(string directory, int depth = 0)
        {
            cancellation.ThrowIfCancellationRequested();
            if (depth > 32 || files.Count >= 20_000) { result.Warnings++; return; }
            try
            {
                if ((File.GetAttributes(directory) & FileAttributes.ReparsePoint) != 0) { result.Warnings++; return; }
                foreach (var entry in Directory.EnumerateFileSystemEntries(directory))
                {
                    cancellation.ThrowIfCancellationRequested();
                    if (files.Count >= 20_000) { result.Warnings++; break; }
                    var a = File.GetAttributes(entry);
                    if ((a & FileAttributes.ReparsePoint) != 0) { result.Warnings++; continue; }
                    if ((a & FileAttributes.Directory) != 0) { Walk(entry, depth + 1); continue; }
                    if (!entry.EndsWith(".jsonl", StringComparison.OrdinalIgnoreCase)) continue;
                    var info = new FileInfo(entry); files.Add((entry, new(info.Length, info.LastWriteTimeUtc.Ticks, info.CreationTimeUtc.Ticks)));
                }
            }
            catch (DirectoryNotFoundException) { }
            catch (FileNotFoundException) { if (Directory.Exists(directory)) result.Warnings++; }
            catch (UnauthorizedAccessException) { result.Warnings++; }
            catch (IOException) { result.Warnings++; }
        }
        Walk(Path.Combine(home, "sessions")); Walk(Path.Combine(home, "archived_sessions"));
        var retained = new HashSet<string>(StringComparer.Ordinal); var unique = new Dictionary<string, (Stamp Stamp, TokenSession Session)>(StringComparer.Ordinal);
        foreach (var f in files.OrderBy(f => f.Path, StringComparer.Ordinal))
        {
            cancellation.ThrowIfCancellationRequested(); result.ScannedFiles++;
            TokenSession session;
            try
            {
                if (cache.TryGetValue(f.Path, out var old) && old.Stamp == f.Stamp) session = old.Session;
                else session = Read(f.Path, Math.Min(f.Stamp.Size, MaxBytes), cancellation);
            }
            catch (UnauthorizedAccessException) { result.Warnings++; continue; }
            catch (IOException) { result.Warnings++; continue; }
            if (f.Stamp.Size > MaxBytes) result.Warnings++;
            cache[f.Path] = (f.Stamp, session); retained.Add(f.Path);
            if (!session.Eligible) { result.ExcludedFiles++; result.Warnings += session.Warnings; continue; }
            if (unique.TryGetValue(session.Id, out var prior) && (prior.Session.Events.Count > session.Events.Count || prior.Session.Events.Count == session.Events.Count && prior.Stamp.Size >= f.Stamp.Size)) continue;
            unique[session.Id] = (f.Stamp, session);
        }
        foreach (var path in cache.Keys.Where(k => !retained.Contains(k)).ToArray()) cache.Remove(path);
        result.Sessions = unique.OrderBy(x => x.Key, StringComparer.Ordinal).Select(x => x.Value.Session).ToList();
        result.Warnings += result.Sessions.Sum(s => s.Warnings); result.FetchedAt = DateTimeOffset.Now; return result;
    }
    static TokenSession Read(string path, long limit, CancellationToken cancellation)
    {
        if ((File.GetAttributes(path) & (FileAttributes.ReparsePoint | FileAttributes.Directory)) != 0) throw new IOException("Not a regular log");
        using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete, 256 * 1024, FileOptions.SequentialScan);
        using var line = new MemoryStream(); var buffer = new byte[256 * 1024]; long consumed = 0; var discard = false; var parser = new TokenLogParser();
        while (consumed < limit)
        {
            cancellation.ThrowIfCancellationRequested();
            var length = stream.Read(buffer, 0, (int)Math.Min(buffer.Length, limit - consumed)); if (length == 0) break; consumed += length;
            var start = 0;
            while (start < length)
            {
                var newline = Array.IndexOf(buffer, (byte)10, start, length - start); var end = newline < 0 ? length : newline;
                if (!discard)
                {
                    if (line.Length + end - start <= 4 * 1024 * 1024) line.Write(buffer, start, end - start);
                    else { line.SetLength(0); discard = true; parser.Session.Warnings++; }
                }
                if (newline < 0) break;
                if (!discard) parser.Consume(line.ToArray());
                line.SetLength(0); discard = false; start = newline + 1;
                if (parser.Session.Id.Length > 0 && !parser.Session.Eligible) return parser.Session;
            }
        }
        if (line.Length > 0 && !discard) parser.Session.Warnings++;
        return parser.Session;
    }
}
public static class TokenCsv
{
    public static string Make(TokenSummary summary)
    {
        var s = new StringBuilder("scope,day,input_tokens,cached_input_tokens,output_tokens,reasoning_output_tokens,total_tokens\r\n");
        foreach (var d in summary.Days)
        {
            var t = d.Tokens;
            s.Append(CultureInfo.InvariantCulture, $"local_codex_desktop,{d.Date:yyyy-MM-dd},{t.Input},{t.Cached},{t.Output},{t.Reasoning},{t.Total}\r\n");
        }
        return s.ToString();
    }
}
