import Foundation

// No secrets are added to metadata. Missing records in older libraries mean OFF.
struct WarmupRecord: Codable, Equatable {
    var enabled = false
    var paused = false
    var lastAttempt: Date?
    var processedReset: Date?
    var lastConfirmed: Date?
    var result: String?
    // v1 was opt-in for a different trigger. Reconfirm before v2 may run immediately.
    var scheduleVersion: Int?
    var nextAt: Date?
}
enum WarmupPolicy {
    static let model = "gpt-6-luna"
    static func quotaReason(_ snapshot: QuotaSnapshot?, now: Date = Date()) -> String? {
        guard let q = snapshot, now >= q.fetchedAt, now.timeIntervalSince(q.fetchedAt) < 90 else { return "额度数据待刷新" }
        guard let five = q.fiveHours, five.resetsAt != nil else { return "未提供 5 小时窗口，暂不预热" }
        guard five.remaining > 0 else { return "5 小时额度已用完，请等待重置" }
        guard let week = q.sevenDays, week.remaining >= 1, let weekReset = week.resetsAt, weekReset > now else { return "7 天额度不足 1% 或数据待确认" }
        return nil
    }
    static func reason(_ record: WarmupRecord, snapshot: QuotaSnapshot?, now: Date = Date(), manual: Bool = false) -> String? {
        if !manual && !record.enabled { return "自动预热已关闭" }
        if !manual && record.scheduleVersion != 2 { return "规则已更新，请重新开启自动预热" }
        if !manual && record.paused { return "自动预热已暂停，请检查后手动重试" }
        if let reason = quotaReason(snapshot, now: now) { return reason }
        if let attempt = record.lastAttempt {
            guard now >= attempt else { return "本机时间异常，请检查后重试" }
            if now.timeIntervalSince(attempt) < (manual ? 60 : 18_000) { return "请求冷却中，稍后再检查" }
        }
        if !manual, let next = record.nextAt, now < next { return "等待下次预热时间" }
        return nil
    }
    static func nextAfterSuccess(attempt: Date, snapshot: QuotaSnapshot) -> Date {
        // Keep the observed reset as an anchor; the next refresh may already report a later window.
        let cooldown = attempt.addingTimeInterval(18_060)
        guard let reset = snapshot.fiveHours?.resetsAt, reset > attempt else { return cooldown }
        return max(cooldown, reset.addingTimeInterval(60))
    }
}
struct WarmupResult {
    let snapshot: QuotaSnapshot
    let sent: Bool
    let confirmed: Bool
    var detail: String? = nil
    var message: String {
        if !sent { return detail ?? "额度状态变化，本次未发送预热消息" }
        return "预热消息已发送 · 窗口状态以官方额度为准"
    }
}
struct WarmupProtocol {
    enum Event { case send([[String: Any]]), result(WarmupResult), ignore }
    private let credentials: QuotaCredentials
    private let directory: String
    private let reset: Date
    private var expected = 1
    private var threadID: String?
    private var turnID: String?
    private var earlyCompletion: [String: Any]?
    private var modelPages = 0
    init(credentials: QuotaCredentials, directory: String, reset: Date) {
        self.credentials = credentials; self.directory = directory; self.reset = reset
    }
    static var initialize: [String: Any] {
        ["id": 1, "method": "initialize", "params": ["clientInfo": ["name": "still_window_warmup", "version": "1.3.0"], "capabilities": ["experimentalApi": true]]]
    }
    mutating func receive(_ object: [String: Any], now: Date = Date()) throws -> Event {
        if let method = object["method"] as? String {
            if object["id"] != nil {
                if method == "account/chatgptAuthTokens/refresh" { throw SwitchError("访问令牌已过期，预热已暂停。请更新登录备份或重新添加账号。") }
                throw SwitchError("预热组件请求了额外操作，任务已停止。")
            }
            if method == "turn/completed", let params = object["params"] as? [String: Any], params["threadId"] as? String == threadID {
                if expected == 6 { earlyCompletion = params; return .ignore }
                if expected == -1 { return try completed(params) }
            }
            // A minimal reply should never run tools; stop on any unexpected tool item.
            if method == "item/started", let params = object["params"] as? [String: Any], params["threadId"] as? String == threadID,
               let item = params["item"] as? [String: Any], let type = item["type"] as? String,
               !["userMessage", "agentMessage", "reasoning"].contains(type) { throw SwitchError("预热出现额外工具操作，任务已停止。") }
            return .ignore
        }
        guard QuotaSnapshot.number(object["id"]) == Double(expected), expected > 0 else { return .ignore }
        if let error = object["error"] as? [String: Any] {
            let stage = [1: "初始化", 2: "临时登录", 3: "额度检查", 4: "模型列表", 5: "会话创建", 6: "消息发送", 7: "结果检查"][expected] ?? "请求"
            let code = (error["code"] as? Int).map { "（代码 \($0)）" } ?? ""
            if expected == 7 { throw SwitchError("消息已发送，但额度复查未完成\(code)；可能已消耗额度，自动预热已暂停。") }
            if expected == 6 { throw SwitchError("预热消息发送未完成\(code)，可能已消耗额度；自动预热已暂停。") }
            throw SwitchError("预热\(stage)未完成\(code)，已暂停自动请求。请检查网络、登录和官方 CLI 版本。")
        }
        guard let result = object["result"] as? [String: Any] else { throw SwitchError("预热响应格式异常，任务已暂停。") }
        switch expected {
        case 1:
            expected = 2
            return .send([["method": "initialized"], ["id": 2, "method": "account/login/start", "params": ["type": "chatgptAuthTokens", "accessToken": credentials.accessToken, "chatgptAccountId": credentials.accountID, "chatgptPlanType": credentials.plan]]])
        case 2:
            guard result["type"] as? String == "chatgptAuthTokens" else { throw SwitchError("官方 CLI 的临时登录协议不匹配，请更新 Codex。") }
            expected = 3; return .send([["id": 3, "method": "account/rateLimits/read"]])
        case 3:
            let q = try QuotaSnapshot.parse(result, now: now)
            // Re-check on the server immediately before a turn; stale UI data never authorizes a request.
            if let reason = WarmupPolicy.quotaReason(q, now: now) {
                return .result(WarmupResult(snapshot: q, sent: false, confirmed: false, detail: reason))
            }
            expected = 4; return .send([["id": 4, "method": "model/list", "params": ["limit": 100, "includeHidden": false]]])
        case 4:
            let models = result["data"] as? [[String: Any]] ?? []
            let available = models.first { $0["model"] as? String == WarmupPolicy.model && $0["hidden"] as? Bool != true }
            if let available, let efforts = available["supportedReasoningEfforts"] as? [[String: Any]], efforts.contains(where: { $0["reasoningEffort"] as? String == "low" }) {
                expected = 5
                return .send([["id": 5, "method": "thread/start", "params": [
                    "model": WarmupPolicy.model, "modelProvider": "openai", "cwd": directory,
                    "approvalPolicy": "never", "sandbox": "read-only", "ephemeral": true,
                    "baseInstructions": "Reply exactly ok. Do not use tools or access files, commands, websites, or other accounts.",
                    "developerInstructions": "This is a single minimal reply. Reply exactly ok.",
                    "config": ["model_reasoning_effort": "low", "web_search": "disabled", "features.shell_tool": false, "features.apps": false, "features.multi_agent": false]
                ]]])
            }
            modelPages += 1
            if available == nil, modelPages < 4, let cursor = result["nextCursor"] as? String, !cursor.isEmpty {
                return .send([["id": 4, "method": "model/list", "params": ["limit": 100, "cursor": cursor, "includeHidden": false]]])
            }
            throw SwitchError("该账号暂未提供 GPT-6 Luna / low，预热已暂停；没有自动换用其他模型。")
        case 5:
            guard let thread = result["thread"] as? [String: Any], let id = thread["id"] as? String, !id.isEmpty,
                  thread["ephemeral"] as? Bool == true, result["model"] as? String == WarmupPolicy.model,
                  result["modelProvider"] as? String == "openai", result["cwd"] as? String == directory,
                  result["approvalPolicy"] as? String == "never", (result["sandbox"] as? [String: Any])?["type"] as? String == "readOnly"
            else { throw SwitchError("临时会话隔离检查未通过，未发送预热消息。") }
            threadID = id; expected = 6
            return .send([["id": 6, "method": "turn/start", "params": [
                "threadId": id, "input": [["type": "text", "text": "回复ok"]],
                "model": WarmupPolicy.model, "effort": "low", "approvalPolicy": "never",
                // The supported cross-version readOnly policy no longer accepts readOnly.access.
                // Read-only is not a guarantee that every existing local file is unreadable.
                "sandboxPolicy": ["type": "readOnly", "networkAccess": false]
            ]]])
        case 6:
            guard let turn = result["turn"] as? [String: Any], let id = turn["id"] as? String, !id.isEmpty else { throw SwitchError("预热消息确认异常，自动重试已暂停。") }
            turnID = id; expected = -1
            if let early = earlyCompletion { earlyCompletion = nil; return try completed(early) }
            return .ignore
        case 7:
            let q = try QuotaSnapshot.parse(result, now: now)
            let confirmed = q.fiveHours?.resetsAt.map { $0 > reset && $0 > now } ?? false
            return .result(WarmupResult(snapshot: q, sent: true, confirmed: confirmed))
        default: return .ignore
        }
    }
    private mutating func completed(_ params: [String: Any]) throws -> Event {
        guard let turn = params["turn"] as? [String: Any], turn["id"] as? String == turnID else { return .ignore }
        guard turn["status"] as? String == "completed" else { throw SwitchError("预热请求未正常完成，可能已消耗额度；自动重试已暂停。") }
        expected = 7; return .send([["id": 7, "method": "account/rateLimits/read"]])
    }
}
