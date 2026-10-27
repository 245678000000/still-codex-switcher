import Foundation

@MainActor enum TokenUsageTests {
    static func run(_ check: (Bool, String) -> Void, root: URL) async throws {
        func meta(_ id: String = "desktop-one", origin: String = "Codex Desktop", extra: [String: Any] = [:]) -> [String: Any] {
            var p: [String: Any] = ["id": id, "originator": origin, "source": "vscode"]
            for (k, v) in extra { p[k] = v }
            return ["type": "session_meta", "payload": p]
        }
        func context(_ model: String = "gpt-fixture") -> [String: Any] { ["type": "turn_context", "payload": ["model": model]] }
        func usage(_ input: Int64, _ output: Int64, cached: Int64 = 0, reasoning: Int64 = 0, date: String = "2026-10-27T01:00:00.000Z") -> [String: Any] {
            ["type": "event_msg", "timestamp": date, "payload": ["type": "token_count", "info": ["total_token_usage": ["input_tokens": input, "cached_input_tokens": cached, "output_tokens": output, "reasoning_output_tokens": reasoning, "total_tokens": input + output]]]]
        }
        func lines(_ records: [[String: Any]]) throws -> Data {
            var d = Data(); for record in records { d.append(try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])); d.append(10) }; return d
        }
        func parse(_ records: [[String: Any]]) throws -> TokenSession {
            var p = TokenLogParser(); for r in records { p.consume(try JSONSerialization.data(withJSONObject: r)) }; return p.session
        }
        let first = usage(1000, 100, cached: 600, reasoning: 40, date: "2026-10-26T15:59:00Z")
        let second = usage(1800, 180, cached: 1000, reasoning: 70)
        let records = [meta(), context(), first, first, context("gpt-fixture-next"), second]
        let parsed = try parse(records)
        check(parsed.eligible && parsed.events.count == 2, "tokens cumulative repeated events deduplicated")
        check(parsed.events[1].tokens == TokenAmounts(input: 800, cached: 400, output: 80, reasoning: 30), "tokens second event uses delta not cumulative sum")
        check(parsed.events[1].model == "gpt-fixture-next", "tokens model changes attributed to new deltas")
        check(parsed.events.reduce(0) { $0 + $1.tokens.total } == 1980, "tokens caches and reasoning not added twice")
        for record in [meta(origin: "codex_vscode"), meta(origin: "codex_exec"), meta(extra: ["parent_thread_id": "parent"]), meta(extra: ["forked_from_id": "parent"]), meta(extra: ["source": ["subagent": "fixture"]])] {
            check(try parse([record, first]).events.isEmpty, "tokens plugins CLI and inherited streams excluded")
        }
        check(try parse([context(), first]).events.isEmpty, "tokens missing origin metadata excluded")
        let rollback = try parse([meta(), first, usage(100, 10), first, second])
        check(rollback.events.count == 2 && rollback.warnings == 1, "tokens regressing and replayed cumulative counters do not inflate total")
        let nullInfo: [String: Any] = ["type": "event_msg", "payload": ["type": "token_count", "info": NSNull()]]
        check(try parse([meta(), first, nullInfo, second]).events.count == 2, "tokens null rate update keeps baseline")
        check(try parse([meta(), usage(-1, 3), usage(20, 3, cached: 99), usage(20, 3, reasoning: 4)]).events.isEmpty, "tokens invalid negative and subset values skipped")
        check(TokenAmounts.read(["input_tokens": true, "output_tokens": 2]) == nil, "tokens boolean counts rejected")
        check(TokenAmounts.read(["input_tokens": 0.5, "output_tokens": 2]) == nil, "tokens fractional counts rejected")
        check(TokenAmounts.read(["input_tokens": 1e20, "output_tokens": 2]) == nil, "tokens oversized counts rejected")
        let badDate = try parse([meta(), usage(100, 10, date: "invalid"), usage(150, 15)])
        check(badDate.events.first?.tokens.total == 55 && badDate.warnings == 1, "tokens missing timestamp delta not reassigned to a later day")
        let privateEvent: [String: Any] = ["type": "response_item", "payload": ["content": "SECRET token_count text"]]
        check(try parse([meta(), privateEvent, first]).events.count == 1, "tokens message content is not telemetry")
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let now = ISO8601DateFormatter().date(from: "2026-10-27T04:00:00Z")!
        let snapshot = TokenSnapshot(sessions: [parsed])
        let today = snapshot.summarize(.today, now: now, calendar: calendar)
        check(today.total.total == 880 && today.sessions == 1, "tokens local midnight partitions cumulative delta")
        let week = snapshot.summarize(.week, now: now, calendar: calendar)
        check(week.total.total == 1980 && week.days.count == 7 && week.models.count == 2, "tokens seven calendar days include empty days and model breakdown")
        check(snapshot.summarize(.month, now: now, calendar: calendar).days.count == 30, "tokens thirty day range")
        var future = snapshot; future.sessions[0].events.append(TokenEvent(date: now.addingTimeInterval(1), model: "future", tokens: TokenAmounts(input: 999)))
        check(future.summarize(.all, now: now, calendar: calendar).total.total == 1980, "tokens future dates excluded")
        var dst = Calendar(identifier: .gregorian); dst.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let dstNow = ISO8601DateFormatter().date(from: "2026-11-03T12:00:00Z")!
        check(TokenSnapshot().summarize(.week, now: dstNow, calendar: dst).days.count == 7, "tokens DST does not duplicate calendar days")
        let csv = TokenCSV.make(today, calendar: calendar)
        check(csv.contains("2026-10-27,800,400,80,30,880") && !csv.contains("desktop-one") && !csv.contains("SECRET"), "tokens CSV contains only dates and numeric aggregates")
        let sessions = root.appendingPathComponent("sessions/2026/10/27")
        let archived = root.appendingPathComponent("archived_sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: archived, withIntermediateDirectories: true)
        let file = sessions.appendingPathComponent("desktop.jsonl")
        let bytes = try lines(records); try bytes.write(to: file)
        try lines([meta(), context(), first]).write(to: archived.appendingPathComponent("copy.jsonl"))
        try lines([meta("cli", origin: "codex_exec"), first]).write(to: sessions.appendingPathComponent("cli.jsonl"))
        let scanner = TokenLogScanner()
        let scan = try await scanner.scan(home: root)
        check(scan.scannedFiles == 3 && scan.excludedFiles == 1 && scan.sessions.count == 1, "tokens scanner includes archived and deduplicates session ids")
        check(scan.summarize(.all, now: now, calendar: calendar).total.total == 1980, "tokens scanner chooses fuller duplicate")
        check(try Data(contentsOf: file) == bytes, "tokens scanning leaves source logs untouched")
        let again = try await scanner.scan(home: root)
        check(again.summarize(.all, now: now, calendar: calendar).total.total == 1980, "tokens cached rescans idempotent")
        var appended = bytes; appended.append(try lines([usage(2000, 200, cached: 1100, reasoning: 75)])); try appended.write(to: file)
        let grown = try await scanner.scan(home: root)
        check(grown.summarize(.all, now: now, calendar: calendar).total.total == 2200, "tokens changed file invalidates cache")
        let tail = try JSONSerialization.data(withJSONObject: usage(2200, 220, cached: 1200, reasoning: 80))
        appended.append(tail); try appended.write(to: file)
        let partial = try await scanner.scan(home: root)
        check(partial.summarize(.all, now: now, calendar: calendar).total.total == 2200 && partial.warnings == 1, "tokens active unterminated tail deferred")
        appended.append(10); try appended.write(to: file)
        let completed = try await scanner.scan(home: root)
        check(completed.summarize(.all, now: now, calendar: calendar).total.total == 2420, "tokens completed tail picked up next scan")
        try FileManager.default.createSymbolicLink(at: sessions.appendingPathComponent("link.jsonl"), withDestinationURL: file)
        let link = try await scanner.scan(home: root)
        check(link.warnings > 0 && link.sessions.count == 1, "tokens symbolic links skipped")
        try FileManager.default.removeItem(at: file)
        let deleted = try await scanner.scan(home: root)
        check(deleted.summarize(.all, now: now, calendar: calendar).total.total == 1100, "tokens deleted source evicted from cache")
        let missing = try await scanner.scan(home: root.appendingPathComponent("missing"))
        check(missing.scannedFiles == 0 && missing.sessions.isEmpty && missing.warnings == 0, "tokens empty directory displays empty state")
    }
}
