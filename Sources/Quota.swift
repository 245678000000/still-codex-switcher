import Foundation
import CoreFoundation

struct QuotaWindow: Equatable {
    let remaining: Double
    let resetsAt: Date?
    var percent: String { String(format: remaining.rounded() == remaining ? "%.0f%%" : "%.1f%%", remaining) }
    func resetLabel(now: Date = Date()) -> String {
        guard let reset = resetsAt else { return "未提供重置时间" }
        guard reset > now else { return "已到重置时间 · 待刷新" }
        let formatter = DateFormatter(); formatter.dateFormat = "MM-dd HH:mm"
        return formatter.string(from: reset) + " 重置"
    }
}
struct QuotaSnapshot: Equatable {
    let fiveHours: QuotaWindow?
    let sevenDays: QuotaWindow?
    let fetchedAt: Date
    var resetCredits: ResetCredits? = nil
    static func number(_ value: Any?) -> Double? {
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite else { return nil }
        return n.doubleValue
    }
    static func parse(_ result: [String: Any], now: Date = Date()) throws -> QuotaSnapshot {
        var bucket: [String: Any]?
        if let map = result["rateLimitsByLimitId"], !(map is NSNull) {
            guard let map = map as? [String: Any] else { throw SwitchError("额度响应格式异常，请稍后重试。") }
            bucket = map["codex"] as? [String: Any]
        } else { bucket = result["rateLimits"] as? [String: Any] }
        if let id = bucket?["limitId"] as? String, id != "codex" { bucket = nil }
        func read(_ duration: Double) -> QuotaWindow? {
            guard let bucket else { return nil }
            let matches = ["primary", "secondary"].compactMap { bucket[$0] as? [String: Any] }.filter { number($0["windowDurationMins"]) == duration }
            guard matches.count == 1, let used = number(matches[0]["usedPercent"]) else { return nil }
            var reset: Date?
            if let seconds = number(matches[0]["resetsAt"]), seconds.rounded() == seconds, (-62_135_596_800...253_402_300_799).contains(seconds) { reset = Date(timeIntervalSince1970: seconds) }
            return QuotaWindow(remaining: min(100, max(0, 100 - used)), resetsAt: reset)
        }
        // Window positions are not durations. Unknown/missing buckets never mean full allowance.
        return QuotaSnapshot(fiveHours: read(300), sevenDays: read(10080), fetchedAt: now, resetCredits: ResetCredits.parse(result["rateLimitResetCredits"]))
    }
}
struct QuotaState {
    var snapshot: QuotaSnapshot?
    var error: String?
    var loading = false
    var attemptedAt: Date?
    func isStale(now: Date = Date()) -> Bool {
        guard let snapshot else { return false }
        return error != nil || now.timeIntervalSince(snapshot.fetchedAt) >= 300 || now < snapshot.fetchedAt ||
            [snapshot.fiveHours?.resetsAt, snapshot.sevenDays?.resetsAt].compactMap { $0 }.contains { $0 <= now }
    }
    func status(now: Date = Date()) -> String {
        let formatter = DateFormatter(); formatter.dateFormat = "HH:mm"
        let time = snapshot.map { " · " + formatter.string(from: $0.fetchedAt) } ?? ""
        if loading { return "正在刷新…" + (snapshot == nil ? "" : " · 上次结果" + time) }
        if let error { return error + (snapshot == nil ? "" : " · 上次结果" + time) }
        guard snapshot != nil else { return "待刷新" }
        return (isStale(now: now) ? "上次结果 · 待刷新" : "已刷新") + time
    }
    func due(now: Date, automatic: Bool) -> Bool { attemptedAt.map { now.timeIntervalSince($0) >= (automatic ? 300 : 30) } ?? true }
}
struct QuotaCredentials: CustomStringConvertible, CustomDebugStringConvertible {
    let accessToken: String
    let accountID: String
    let plan: String
    var description: String { "QuotaCredentials [redacted]" }
    var debugDescription: String { description }
    static func read(_ data: Data, expectedKey: String) throws -> QuotaCredentials {
        let identity = try Identity.read(data)
        guard identity.key == expectedKey else { throw SwitchError("保存的账号与登录资料不一致，请重新添加。") }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any], let tokens = obj["tokens"] as? [String: Any],
              let access = tokens["access_token"] as? String, access.utf8.count <= 65_536 else { throw SwitchError("登录资料格式异常，请重新添加。") }
        var account = tokens["account_id"] as? String
        if account == nil, let raw = tokens["id_token"] as? String {
            let parts = raw.components(separatedBy: ".")
            var base = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            base += String(repeating: "=", count: (4 - base.count % 4) % 4)
            if let bytes = Data(base64Encoded: base), let claims = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] {
                account = (claims["https://api.openai.com/auth"] as? [String: Any])?["chatgpt_account_id"] as? String
            }
        }
        guard let account, !account.isEmpty else { throw SwitchError("缺少账号工作区信息，请重新添加。") }
        return QuotaCredentials(accessToken: access, accountID: account, plan: identity.plan)
    }
}
struct QuotaProtocol {
    enum Event { case send([[String: Any]]), result(QuotaSnapshot), ignore }
    private var expected = 1
    private let credentials: QuotaCredentials
    init(credentials: QuotaCredentials) { self.credentials = credentials }
    static var initialize: [String: Any] { ["id": 1, "method": "initialize", "params": ["clientInfo": ["name": "still_codex_switcher_macos", "title": "Still quota viewer", "version": "1.1.0"], "capabilities": ["experimentalApi": true]]] }
    mutating func receive(_ object: [String: Any], now: Date = Date()) throws -> Event {
        if let method = object["method"] as? String {
            guard let id = object["id"] else { return .ignore }
            if method == "account/chatgptAuthTokens/refresh" { throw SwitchError("登录已过期，请更新登录备份或重新添加账号。") }
            return .send([["id": id, "error": ["code": -32601, "message": "This viewer does not run tools or renew tokens."]]])
        }
        guard QuotaSnapshot.number(object["id"]) == Double(expected) else { return .ignore }
        if let error = object["error"] as? [String: Any] {
            let code = QuotaSnapshot.number(error["code"])
            throw SwitchError(code == -32601 || code == -32602 ? "当前 CLI 的额度协议不兼容，请更新官方 Codex。" : "额度查询失败，请检查网络或更新登录备份。")
        }
        guard let result = object["result"] as? [String: Any] else { throw SwitchError("额度响应缺少结果。") }
        switch expected {
        case 1:
            expected = 2
            // Only the access token is passed to this private child; no refresh token rotation.
            return .send([["method": "initialized"], ["id": 2, "method": "account/login/start", "params": ["type": "chatgptAuthTokens", "accessToken": credentials.accessToken, "chatgptAccountId": credentials.accountID, "chatgptPlanType": credentials.plan]]])
        case 2:
            guard result["type"] as? String == "chatgptAuthTokens" else { throw SwitchError("当前 CLI 的额度协议不兼容，请更新官方 Codex。") }
            expected = 3; return .send([["id": 3, "method": "account/rateLimits/read"]])
        default: return .result(try QuotaSnapshot.parse(result, now: now))
        }
    }
}
