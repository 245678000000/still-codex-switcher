import Foundation

enum DiagnosticLevel { case passed, attention, unknown }
struct DiagnosticCheck: Identifiable {
    let id: String
    let title: String
    let level: DiagnosticLevel
    let detail: String
}
struct DiagnosticReport {
    let checkedAt: Date
    let checks: [DiagnosticCheck]
    var quota: QuotaSnapshot? = nil
    var models: [String] = []
    static let boundary = "基础检查不发送聊天消息。模型目录不等于实际推理验证；本结果不是风控或模型身份判定。"
    var summary: String { checks.contains { $0.level == .attention } ? "有项目需要处理" : checks.contains { $0.level == .unknown } ? "部分项目待确认" : "基础检查已完成" }
    func isStale(now: Date = Date()) -> Bool {
        now < checkedAt || now.timeIntervalSince(checkedAt) >= 300 || [quota?.fiveHours?.resetsAt, quota?.sevenDays?.resetsAt].compactMap { $0 }.contains { $0 <= now }
    }
    static func fromQuota(_ q: QuotaSnapshot) -> DiagnosticReport {
        let unknown = q.fiveHours == nil || q.sevenDays == nil
        let empty = [q.fiveHours, q.sevenDays].compactMap { $0 }.contains { $0.remaining <= 0 }
        let detail = "5 小时 \(q.fiveHours?.percent ?? "—") · 7 天 \(q.sevenDays?.percent ?? "—")" + (empty ? " · 请等待官方重置" : unknown ? " · 缺失窗口保留为未知" : " · 以官方窗口为准")
        return DiagnosticReport(checkedAt: q.fetchedAt, checks: [DiagnosticCheck(id: "quota", title: "剩余额度", level: empty ? .attention : unknown ? .unknown : .passed, detail: detail)], quota: q)
    }
    static func interrupted(_ reason: String, now: Date = Date()) -> DiagnosticReport {
        DiagnosticReport(checkedAt: now, checks: [DiagnosticCheck(id: "execution", title: "本次检查未完成", level: .unknown, detail: reason)])
    }
}
// Only read methods are emitted. External-token login is not itself proof of service acceptance.
struct DiagnosticProtocol {
    enum Event { case send([[String: Any]]), result(DiagnosticReport), ignore }
    private let credentials: QuotaCredentials
    private var expected = 1
    private var pages = 0
    private var cursors = Set<String>()
    private var models = Set<String>()
    private var checks = [DiagnosticCheck(id: "credentials", title: "账号凭据", level: .passed, detail: "本地资料与所选账号匹配；未刷新或回写凭证")]
    private var quota: QuotaSnapshot?
    init(credentials: QuotaCredentials) { self.credentials = credentials }
    static var initialize: [String: Any] { ["id": 1, "method": "initialize", "params": ["clientInfo": ["name": "still_account_diagnostics", "version": "1.0.0"], "capabilities": ["experimentalApi": true]]] }
    private func modelRequest(_ cursor: String? = nil) -> [String: Any] {
        var params: [String: Any] = ["limit": 100, "includeHidden": false]
        if let cursor { params["cursor"] = cursor }
        return ["id": 4, "method": "model/list", "params": params]
    }
    private mutating func finish(_ now: Date) -> Event {
        expected = -1
        return .result(DiagnosticReport(checkedAt: now, checks: checks, quota: quota, models: models.sorted()))
    }
    mutating func receive(_ obj: [String: Any], now: Date = Date()) throws -> Event {
        guard expected > 0 else { return .ignore }
        if let method = obj["method"] as? String {
            if obj["id"] != nil {
                checks.append(DiagnosticCheck(id: "request", title: "官方服务", level: .attention, detail: method == "account/chatgptAuthTokens/refresh" ? "访问令牌需更新，请在 Codex 登录后更新备份或重新添加账号" : "组件请求了额外操作，检查已停止"))
                return finish(now)
            }
            return .ignore
        }
        guard QuotaSnapshot.number(obj["id"]) == Double(expected) else { return .ignore }
        if let error = obj["error"] as? [String: Any] {
            let reason: String
            switch QuotaSnapshot.number(error["code"]) {
            case -32601, -32602: reason = "CLI 协议不兼容，请更新官方 Codex"
            case 401: reason = "服务返回认证失败，请更新登录备份"
            case 403: reason = "服务拒绝本次访问，请到官方客户端核对；原因待确认"
            case 429: reason = "请求受限，请稍后重试；额度与频率限制需分别核对"
            default: reason = "请求未完成，请检查网络、登录备份及 CLI 版本；原因待确认"
            }
            checks.append(DiagnosticCheck(id: expected == 4 ? "models" : "service", title: expected == 4 ? "模型目录" : "官方额度接口", level: .attention, detail: reason))
            if expected == 3 { expected = 4; return .send([modelRequest()]) }
            return finish(now)
        }
        guard let result = obj["result"] as? [String: Any] else { throw SwitchError("诊断响应缺少结果。") }
        switch expected {
        case 1:
            expected = 2
            return .send([["method": "initialized"], ["id": 2, "method": "account/login/start", "params": ["type": "chatgptAuthTokens", "accessToken": credentials.accessToken, "chatgptAccountId": credentials.accountID, "chatgptPlanType": credentials.plan]]])
        case 2:
            guard result["type"] as? String == "chatgptAuthTokens" else { throw SwitchError("诊断临时登录协议不匹配。") }
            expected = 3; return .send([["id": 3, "method": "account/rateLimits/read"]])
        case 3:
            let q = try QuotaSnapshot.parse(result, now: now); quota = q
            checks.append(DiagnosticCheck(id: "service", title: "官方额度接口", level: .passed, detail: "本次额度读取成功；不代表所有模型请求均可用"))
            checks += DiagnosticReport.fromQuota(q).checks
            expected = 4; return .send([modelRequest()])
        case 4:
            guard let data = result["data"] as? [[String: Any]], data.count <= 100 else { throw SwitchError("模型目录响应格式异常。") }
            let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._/")
            for model in data {
                if let name = model["model"] as? String, !name.isEmpty, name.utf8.count <= 120,
                   name.unicodeScalars.allSatisfy({ allowed.contains($0) }), model["hidden"] as? Bool != true { models.insert(name) }
            }
            pages += 1
            let next = result["nextCursor"] as? String
            if let next, !next.isEmpty, next.utf8.count <= 4096, pages < 4, cursors.insert(next).inserted { return .send([modelRequest(next)]) }
            let partial = next?.isEmpty == false
            checks.append(DiagnosticCheck(id: "models", title: "模型目录", level: models.isEmpty || partial ? .unknown : .passed,
                detail: models.isEmpty ? "未返回可展示模型；尚未验证实际推理" : "读取到 \(models.count) 个模型标识" + (partial ? " · 列表未完整返回" : "") + " · 可能来自 CLI 缓存，尚未验证实际推理"))
            return finish(now)
        default: return .ignore
        }
    }
}
