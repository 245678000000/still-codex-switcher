import Foundation
import Darwin
import CoreFoundation

// Local telemetry only: never load auth, account metadata, message bodies or tool output into the snapshot.
struct TokenAmounts: Equatable, Sendable {
    var input: Int64 = 0
    var cached: Int64 = 0
    var output: Int64 = 0
    var reasoning: Int64 = 0
    var total: Int64 { input + output }
    static func + (a: Self, b: Self) -> Self {
        Self(input: a.input + b.input, cached: a.cached + b.cached, output: a.output + b.output, reasoning: a.reasoning + b.reasoning)
    }
    static func read(_ value: Any?) -> Self? {
        guard let o = value as? [String: Any] else { return nil }
        func number(_ key: String, optional: Bool = false) -> Int64? {
            if o[key] == nil && optional { return 0 }
            guard let n = o[key] as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(),
                  n.doubleValue.isFinite, n.doubleValue >= 0, n.doubleValue <= 1_000_000_000_000,
                  n.doubleValue.rounded(.towardZero) == n.doubleValue else { return nil }
            return n.int64Value
        }
        guard let i = number("input_tokens"), let c = number("cached_input_tokens", optional: true),
              let o = number("output_tokens"), let r = number("reasoning_output_tokens", optional: true),
              c <= i, r <= o else { return nil }
        return Self(input: i, cached: c, output: o, reasoning: r)
    }
    func delta(after previous: Self) -> Self? {
        guard input >= previous.input, cached >= previous.cached, output >= previous.output, reasoning >= previous.reasoning else { return nil }
        let d = Self(input: input - previous.input, cached: cached - previous.cached, output: output - previous.output, reasoning: reasoning - previous.reasoning)
        guard d.cached <= d.input, d.reasoning <= d.output else { return nil }
        return d
    }
}
struct TokenEvent: Sendable {
    var date: Date
    var model: String
    var tokens: TokenAmounts
}
struct TokenSession: Sendable {
    var id: String = ""
    var eligible = false
    var events: [TokenEvent] = []
    var warnings = 0
}

// One file is one cumulative counter stream. Repeated notifications and rollback/replayed counters
// do not get summed again. Forks/subagents are excluded: inherited history has no reliable billing boundary.
struct TokenLogParser {
    var session = TokenSession()
    private var metadataSeen = false
    private var previous = TokenAmounts()
    private var model = "未知模型"
    private let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
    private let plain = ISO8601DateFormatter()
    mutating func consume(_ line: Data) {
        // Large message events are discarded by the reader. Only parse the three telemetry record types.
        guard line.range(of: Data("\"session_meta\"".utf8)) != nil || line.range(of: Data("\"turn_context\"".utf8)) != nil || line.range(of: Data("\"token_count\"".utf8)) != nil else { return }
        guard let o = try? JSONSerialization.jsonObject(with: line) as? [String: Any], let type = o["type"] as? String,
              let p = o["payload"] as? [String: Any] else { session.warnings += 1; return }
        if type == "session_meta" {
            guard !metadataSeen else { return }; metadataSeen = true
            session.id = p["id"] as? String ?? p["session_id"] as? String ?? ""
            // The official desktop labels source as "vscode" too; originator is the discriminator.
            session.eligible = p["originator"] as? String == "Codex Desktop" && p["source"] is String
                && p["parent_thread_id"] == nil && p["forked_from_id"] == nil && !session.id.isEmpty
            return
        }
        guard session.eligible else { return }
        if type == "turn_context" {
            if let value = p["model"] as? String, !value.isEmpty, value.utf8.count <= 80,
               value.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45,46,95,47,58].contains($0) }) { model = value }
            else { model = "未知模型" }
            return
        }
        guard type == "event_msg", p["type"] as? String == "token_count" else { return }
        // info:null is a rate-limit update, not zero consumption.
        guard let info = p["info"] as? [String: Any] else { return }
        guard let current = TokenAmounts.read(info["total_token_usage"]) else { session.warnings += 1; return }
        guard let delta = current.delta(after: previous) else { session.warnings += 1; return }
        previous = current
        guard delta.total > 0 else { return }
        guard let text = o["timestamp"] as? String, let date = fractional.date(from: text) ?? plain.date(from: text) else { session.warnings += 1; return }
        session.events.append(TokenEvent(date: date, model: model, tokens: delta))
    }
}

enum TokenPeriod: String, CaseIterable, Identifiable {
    case today = "今日", week = "近 7 天", month = "近 30 天", all = "全部"
    var id: String { rawValue }
    func start(now: Date, calendar: Calendar) -> Date? {
        guard self != .all else { return nil }
        return calendar.date(byAdding: .day, value: self == .today ? 0 : self == .week ? -6 : -29, to: calendar.startOfDay(for: now))
    }
}
struct TokenBucket: Identifiable {
    var id: String
    var tokens: TokenAmounts
}
struct TokenDay: Identifiable {
    var date: Date
    var tokens: TokenAmounts
    var id: Date { date }
}
struct TokenSummary {
    var total: TokenAmounts
    var sessions: Int
    var days: [TokenDay]
    var models: [TokenBucket]
}
struct TokenSnapshot: Sendable {
    var sessions: [TokenSession] = []
    var scannedFiles = 0
    var excludedFiles = 0
    var warnings = 0
    var fetchedAt = Date()
    func summarize(_ period: TokenPeriod, now: Date = Date(), calendar: Calendar = .current) -> TokenSummary {
        let start = period.start(now: now, calendar: calendar)
        var total = TokenAmounts(), dayMap: [Date: TokenAmounts] = [:], modelMap: [String: TokenAmounts] = [:], count = 0
        for session in sessions {
            let events = session.events.filter { (start == nil || $0.date >= start!) && $0.date <= now }
            if !events.isEmpty { count += 1 }
            for e in events {
                total = total + e.tokens
                let day = calendar.startOfDay(for: e.date)
                dayMap[day] = (dayMap[day] ?? TokenAmounts()) + e.tokens
                modelMap[e.model] = (modelMap[e.model] ?? TokenAmounts()) + e.tokens
            }
        }
        // Zero-fill calendar days (not 86400-second offsets) across DST transitions.
        if let first = start ?? dayMap.keys.min() {
            var d = first; var iterations = 0
            while d <= now && iterations < 3660 {
                if dayMap[d] == nil { dayMap[d] = TokenAmounts() }
                guard let next = calendar.date(byAdding: .day, value: 1, to: d), next > d else { break }
                d = next; iterations += 1
            }
        }
        return TokenSummary(total: total, sessions: count, days: dayMap.map { TokenDay(date: $0.key, tokens: $0.value) }.sorted { $0.date < $1.date },
                            models: modelMap.map { TokenBucket(id: $0.key, tokens: $0.value) }.sorted { $0.tokens.total == $1.tokens.total ? $0.id < $1.id : $0.tokens.total > $1.tokens.total })
    }
}

actor TokenLogScanner {
    private struct Stamp: Equatable { var size: Int64; var modified: Int; var nanos: Int; var inode: UInt64 }
    private var cache: [String: (Stamp, TokenSession)] = [:]
    func scan(home: URL) throws -> TokenSnapshot {
        let fm = FileManager.default
        var snapshot = TokenSnapshot(), files: [(URL, Stamp)] = []
        for directory in ["sessions", "archived_sessions"] {
            let root = home.appendingPathComponent(directory)
            var s = stat()
            guard lstat(root.path, &s) == 0 else { if errno != ENOENT { snapshot.warnings += 1 }; continue }
            guard s.st_mode & S_IFMT == S_IFDIR, s.st_uid == getuid() else { snapshot.warnings += 1; continue }
            var enumerationErrors = 0
            let walk = fm.enumerator(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey], options: [.skipsHiddenFiles], errorHandler: { _, _ in enumerationErrors += 1; return true })
            while let url = walk?.nextObject() as? URL {
                try Task.checkCancellation()
                guard files.count < 20_000 else { snapshot.warnings += 1; break }
                var st = stat()
                guard lstat(url.path, &st) == 0 else { snapshot.warnings += 1; continue }
                if st.st_mode & S_IFMT == S_IFLNK { walk?.skipDescendants(); snapshot.warnings += 1; continue }
                guard url.pathExtension == "jsonl" else { continue }
                guard st.st_mode & S_IFMT == S_IFREG, st.st_uid == getuid() else { snapshot.warnings += 1; continue }
                files.append((url, Stamp(size: st.st_size, modified: st.st_mtimespec.tv_sec, nanos: st.st_mtimespec.tv_nsec, inode: st.st_ino)))
            }
            snapshot.warnings += enumerationErrors
        }
        var retained: [String: (Stamp, TokenSession)] = [:], unique: [String: (Stamp, TokenSession)] = [:]
        for (url, stamp) in files.sorted(by: { $0.0.path < $1.0.path }) {
            try Task.checkCancellation()
            snapshot.scannedFiles += 1
            let parsed: TokenSession
            if let prior = cache[url.path], prior.0 == stamp { parsed = prior.1 }
            else {
                do { parsed = try Self.read(url, byteLimit: min(stamp.size, 512 * 1024 * 1024)) }
                catch is CancellationError { throw CancellationError() }
                catch { snapshot.warnings += 1; continue }
            }
            if stamp.size > 512 * 1024 * 1024 { snapshot.warnings += 1 }
            retained[url.path] = (stamp, parsed)
            if !parsed.eligible { snapshot.warnings += parsed.warnings }
            guard parsed.eligible else { snapshot.excludedFiles += 1; continue }
            // An archived/live duplicate contributes one stream, choosing the fuller copy.
            if let old = unique[parsed.id], old.1.events.count > parsed.events.count || (old.1.events.count == parsed.events.count && old.0.size >= stamp.size) { continue }
            unique[parsed.id] = (stamp, parsed)
        }
        cache = retained
        snapshot.sessions = unique.keys.sorted().compactMap { unique[$0]?.1 }
        snapshot.warnings += snapshot.sessions.reduce(0) { $0 + $1.warnings }
        snapshot.fetchedAt = Date()
        return snapshot
    }
    private static func read(_ url: URL, byteLimit: Int64) throws -> TokenSession {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw SwitchError("部分日志暂未读取，请稍后刷新。") }
        let h = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? h.close() }
        var s = stat()
        guard fstat(fd, &s) == 0, s.st_mode & S_IFMT == S_IFREG, s.st_uid == getuid() else { throw SwitchError("已跳过非普通日志文件。") }
        var parser = TokenLogParser(), line = Data(), discarding = false, readBytes: Int64 = 0
        while readBytes < byteLimit {
            try Task.checkCancellation()
            let chunk = try h.read(upToCount: Int(min(256 * 1024, byteLimit - readBytes))) ?? Data()
            if chunk.isEmpty { break }; readBytes += Int64(chunk.count)
            var start = chunk.startIndex
            while start < chunk.endIndex {
                let newline = chunk[start...].firstIndex(of: 10)
                let end = newline ?? chunk.endIndex
                if !discarding {
                    if line.count + end - start <= 4 * 1024 * 1024 { line.append(chunk[start..<end]) }
                    else { line.removeAll(keepingCapacity: true); discarding = true; parser.session.warnings += 1 }
                }
                if let newline {
                    if !discarding { parser.consume(line) }
                    line.removeAll(keepingCapacity: true); discarding = false; start = newline + 1
                    if !parser.session.id.isEmpty && !parser.session.eligible { return parser.session }
                } else { break }
            }
        }
        // A writer can be mid-record. Ignore the unterminated tail until the next scan.
        if !line.isEmpty && !discarding { parser.session.warnings += 1 }
        return parser.session
    }
}

enum TokenCSV {
    static func make(_ summary: TokenSummary, calendar: Calendar = .current) -> String {
        let f = DateFormatter(); f.calendar = calendar; f.timeZone = calendar.timeZone; f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"
        var lines = ["scope,day,input_tokens,cached_input_tokens,output_tokens,reasoning_output_tokens,total_tokens"]
        for day in summary.days {
            let t = day.tokens
            lines.append("local_codex_desktop,\(f.string(from: day.date)),\(t.input),\(t.cached),\(t.output),\(t.reasoning),\(t.total)")
        }
        return lines.joined(separator: "\r\n") + "\r\n"
    }
}
