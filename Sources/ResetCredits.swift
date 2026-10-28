import Foundation

struct ResetCredit: Equatable {
    let id: String
    let resetType: String
    let status: String
    let expiresAt: Date?
    let expiryKnown: Bool
    func usable(now: Date) -> Bool { status == "available" && resetType == "codexRateLimits" && expiryKnown && (expiresAt == nil || expiresAt! > now) }
}
struct ResetCredits: Equatable {
    let availableCount: Int
    let credits: [ResetCredit]?
    static func parse(_ raw: Any?) -> ResetCredits? {
        guard let obj = raw as? [String: Any], let count = QuotaSnapshot.number(obj["availableCount"]), count >= 0, count <= 1_000_000, count.rounded() == count else { return nil }
        var details: [ResetCredit]?
        if let rows = obj["credits"] as? [[String: Any]], rows.count <= 10_000 {
            var ids = Set<String>()
            details = rows.compactMap { row in
                guard let id = row["id"] as? String, !id.isEmpty, id.utf8.count <= 1024, !id.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }), ids.insert(id).inserted else { return nil }
                var expiry: Date?
                var known = row["expiresAt"] is NSNull
                if let seconds = QuotaSnapshot.number(row["expiresAt"]), seconds.rounded() == seconds, (0...253_402_300_799).contains(seconds) { expiry = Date(timeIntervalSince1970: seconds); known = true }
                return ResetCredit(id: id, resetType: row["resetType"] as? String ?? "unknown", status: row["status"] as? String ?? "unknown", expiresAt: expiry, expiryKnown: known)
            }
        }
        return ResetCredits(availableCount: Int(count), credits: details)
    }
    var countLabel: String { "重置卡 \(availableCount) 张" }
    func hasExpiredDetail(now: Date) -> Bool { credits?.contains { $0.status == "available" && $0.expiresAt.map { $0 <= now } == true } == true }
    func preferredID(now: Date) -> String? {
        credits?.filter { $0.usable(now: now) }.sorted { ($0.expiresAt ?? .distantFuture) < ($1.expiresAt ?? .distantFuture) }.first?.id
    }
    static func dateLabel(_ date: Date) -> String { let f = DateFormatter(); f.dateFormat = "MM-dd HH:mm"; return f.string(from: date) }
    func expiryLabel(now: Date = Date()) -> String {
        if availableCount == 0 { return "暂无可用卡" }
        guard let credits, !credits.isEmpty else { return "有效期待确认" }
        if hasExpiredDetail(now: now) { return "有卡已到期 · 请刷新" }
        let available = credits.filter { $0.status == "available" }
        let complete = available.count == availableCount && available.allSatisfy { $0.expiryKnown }
        if let first = available.compactMap(\.expiresAt).min() { return (complete ? "最近一张 " : "已知最早 ") + Self.dateLabel(first) + " 到期" }
        return complete ? "无到期限制" : "部分有效期待确认"
    }
    func details(now: Date = Date()) -> String {
        let rows = (credits ?? []).filter { $0.status == "available" }
        guard !rows.isEmpty else { return countLabel + "\n服务暂未返回每张卡的有效期。" }
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm zzz"
        let lines = rows.enumerated().map { i, row in
            "第 \(i + 1) 张 · " + (row.expiresAt.map { f.string(from: $0) + ($0 <= now ? " 已到期" : " 到期") } ?? (row.expiryKnown ? "无到期限制" : "有效期待确认"))
        }
        return ([countLabel] + lines + (rows.count < availableCount ? ["仅返回部分卡片详情，其余有效期待确认。"] : [])).joined(separator: "\n")
    }
}
extension QuotaState {
    func canStartReset(now: Date = Date()) -> Bool {
        guard let cards = snapshot?.resetCredits else { return false }
        return cards.availableCount > 0 && !loading && !isStale(now: now) && !cards.hasExpiredDetail(now: now)
    }
}

// Persist before the network call. An uncertain result must retain this same logical attempt.
struct ResetAttempt: Codable, Equatable {
    let idempotencyKey: String
    let creditID: String?
    let createdAt: Date
    static func prepare(existing: ResetAttempt?, state: QuotaState, confirmed: Bool, now: Date = Date(), lastResetAt: Date? = nil) throws -> ResetAttempt? {
        guard confirmed else { return nil }
        if let existing {
            guard UUID(uuidString: existing.idempotencyKey) != nil else { throw SwitchError("上次请求记录异常，请先在官方用量页核对。") }
            return existing
        }
        if let lastResetAt, (state.snapshot?.fetchedAt ?? .distantPast) <= lastResetAt { throw SwitchError("账号已完成过一次重置，请重新刷新卡片后再操作。") }
        guard state.canStartReset(now: now) else { throw SwitchError("请先刷新重置卡信息，确认存在可用卡。") }
        return ResetAttempt(idempotencyKey: UUID().uuidString, creditID: state.snapshot?.resetCredits?.preferredID(now: now), createdAt: now)
    }
}
enum ResetOutcome: String {
    case reset, nothingToReset, noCredit, alreadyRedeemed
    var message: String {
        switch self {
        case .reset: return "已使用 1 张重置卡 · 额度已重置"
        case .alreadyRedeemed: return "上次重置已生效 · 本次未重复扣卡"
        case .nothingToReset: return "当前额度无需重置 · 未消耗重置卡"
        case .noCredit: return "官方服务显示暂无可用重置卡"
        }
    }
}
struct ResetProtocol {
    enum Event { case send([[String: Any]]), result(ResetOutcome), ignore }
    private let credentials: QuotaCredentials
    private let attempt: ResetAttempt
    private var expected = 1
    init(credentials: QuotaCredentials, attempt: ResetAttempt) { self.credentials = credentials; self.attempt = attempt }
    mutating func receive(_ object: [String: Any]) throws -> Event {
        guard expected != 0 else { return .ignore }
        if let method = object["method"] as? String {
            guard object["id"] != nil else { return .ignore }
            throw SwitchError(method == "account/chatgptAuthTokens/refresh" ? "登录需更新，请在官方客户端登录后更新备份；本次请求标识已保留。" : "官方组件请求了额外操作，本次已停止；请求标识已保留。")
        }
        guard QuotaSnapshot.number(object["id"]) == Double(expected) else { return .ignore }
        if let error = object["error"] as? [String: Any] {
            let code = QuotaSnapshot.number(error["code"])
            throw SwitchError(code == -32601 || code == -32602 ? "当前官方 CLI 尚不支持重置卡操作，请更新 Codex；请求标识已保留。" : "重置结果待确认，请核对上次请求；重试会沿用同一标识。")
        }
        guard let result = object["result"] as? [String: Any] else { throw SwitchError("重置结果待确认；本次请求标识已保留。") }
        switch expected {
        case 1:
            expected = 2
            return .send([["method": "initialized"], ["id": 2, "method": "account/login/start", "params": ["type": "chatgptAuthTokens", "accessToken": credentials.accessToken, "chatgptAccountId": credentials.accountID, "chatgptPlanType": credentials.plan]]])
        case 2:
            guard result["type"] as? String == "chatgptAuthTokens" else { throw SwitchError("官方 CLI 登录协议不匹配；请求标识已保留。") }
            expected = 3
            var params: [String: Any] = ["idempotencyKey": attempt.idempotencyKey]
            if let id = attempt.creditID { params["creditId"] = id }
            return .send([["id": 3, "method": "account/rateLimitResetCredit/consume", "params": params]])
        default:
            guard let value = result["outcome"] as? String, let outcome = ResetOutcome(rawValue: value) else { throw SwitchError("重置结果待确认；本次请求标识已保留。") }
            expected = 0; return .result(outcome)
        }
    }
}
