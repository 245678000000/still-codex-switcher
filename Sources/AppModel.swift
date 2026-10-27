import AppKit
import SwiftUI

@MainActor final class SwitcherModel: ObservableObject {
    @Published var library = SwitchLibrary()
    @Published var current: Identity?
    @Published var desktop: CodexDesktop?
    @Published var page = "accounts"
    @Published var query = ""
    @Published var message = ""
    @Published var errorText: String?
    @Published var busy = false
    @Published var loginWaiting = false
    @Published var phase = ""
    @Published var libraryReady = true
    @Published var editing: SavedAccount?
    let paths: AppPaths
    let vault: SecretVault
    let demo: Bool
    let updater: UpdateController
    let broker = LoginBroker()
    @Published var quotas: [UUID: QuotaState] = [:]
    @Published private(set) var refreshingQuotas = false
    private var quotaTask: Task<Void, Never>?
    @Published private(set) var warmingAccountID: UUID?
    @Published private var warmupNotices: [UUID: String] = [:]
    func warmupEnabled(_ account: SavedAccount) -> Bool { account.warmup?.enabled == true && account.warmup?.scheduleVersion == 2 }
    var hasAutoWarmup: Bool { library.accounts.contains { warmupEnabled($0) && $0.warmup?.paused != true } }

    private var operation: OperationLock?
    private var observer: NSObjectProtocol?
    var accounts: [SavedAccount] {
        library.accounts.filter { query.isEmpty || ($0.label + $0.email).localizedCaseInsensitiveContains(query) }
    }
    var active: SavedAccount? { library.accounts.first { $0.identityKey == current?.key } }
    var appearance: ColorScheme? { library.appearance == "dark" ? .dark : library.appearance == "light" ? .light : nil }
    init(paths: AppPaths = .live(), vault: SecretVault = KeychainVault(), demo: Bool = false) {
        self.paths = paths; self.vault = vault; self.demo = demo
        self.updater = UpdateController(demo: demo)
        if demo {
            library.accounts = DemoData.accounts
            current = Identity(key: library.accounts[0].identityKey, email: library.accounts[0].email, plan: "plus")
            message = "界面演示 · 使用虚构账号，不读取或切换真实登录状态。"
            let now = Date()
            quotas[library.accounts[0].id] = QuotaState(snapshot: QuotaSnapshot(fiveHours: QuotaWindow(remaining: 76, resetsAt: now.addingTimeInterval(10800)), sevenDays: QuotaWindow(remaining: 42, resetsAt: now.addingTimeInterval(345600)), fetchedAt: now))
            quotas[library.accounts[1].id] = QuotaState(snapshot: QuotaSnapshot(fiveHours: QuotaWindow(remaining: 18, resetsAt: now.addingTimeInterval(2400)), sevenDays: QuotaWindow(remaining: 8, resetsAt: now.addingTimeInterval(86400)), fetchedAt: now))
            return
        }
        do { library = try SecureFile.loadLibrary(paths.metadata) }
        catch { libraryReady = false; errorText = "账号列表读取异常，原文件已保留。请检查本地数据目录。" }
        refresh()
        // Detect account changes after the user logs in through Codex itself.
        observer = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in guard let self, !self.busy else { return }; self.refresh() }
        }
    }
    func refresh() {
        guard !demo else { return }
        desktop = CodexDesktop.find()
        do {
            try SecureFile.checkFileMode(paths.config)
            current = try SecureFile.read(paths.auth).map(Identity.read)
        } catch { current = nil; message = error.localizedDescription }
    }
    func show(_ error: Error) { errorText = error.localizedDescription }
    private func begin(_ text: String) throws {
        guard !busy, libraryReady else { throw SwitchError("请先完成当前操作并检查账号列表。") }
        operation = try OperationLock(paths.root)
        // Reload while holding the inter-process lock; another switcher may have updated it.
        do { library = try SecureFile.loadLibrary(paths.metadata) }
        catch { operation = nil; throw error }
        busy = true; phase = text; message = ""
    }
    private func end() { busy = false; loginWaiting = false; phase = ""; operation = nil }
    private func store(_ data: Data) throws {
        let identity = try Identity.read(data)
        var next = library
        let existing = next.accounts.firstIndex { $0.identityKey == identity.key }
        let id = existing.map { next.accounts[$0].id } ?? UUID()
        let key = id.uuidString
        let previous = try vault.get(key)
        let old = existing.map { next.accounts[$0] }
        let name = identity.email.contains("@") ? String(identity.email.split(separator: "@")[0]) : "我的账号"
        let account = SavedAccount(id: id, identityKey: identity.key, label: old?.label ?? name,
                                   email: identity.email, plan: identity.plan, savedAt: Date(), color: old?.color ?? next.accounts.count % 4, warmup: old?.warmup)
        if let existing { next.accounts[existing] = account } else { next.accounts.append(account) }
        try vault.put(data, for: key)
        do { try SecureFile.saveLibrary(next, to: paths.metadata); library = next }
        catch {
            if let previous { try? vault.put(previous, for: key) } else { try? vault.remove(key) }
            throw SwitchError("保存账号列表未完成，登录文件保持不变。请检查本地磁盘空间。")
        }
    }
    func saveCurrent() {
        guard !demo else { message = "演示模式：正式版点击这里会保存当前 Codex 登录状态。"; return }
        do {
            try begin("保存当前账号…"); defer { end() }
            try SecureFile.checkFileMode(paths.config)
            guard let data = try SecureFile.read(paths.auth) else { throw SwitchError("请先在 Codex 里登录一次，再保存当前账号。") }
            try store(data); refresh(); message = "当前账号已保存到本机钥匙串。以后可直接点击切换。"
        } catch { show(error) }
    }
    func addAccount() {
        guard !busy else { return }
        guard !demo else { message = "演示模式：正式版会在浏览器打开官方登录，保留当前 Codex 账号。"; return }
        do {
            try begin("准备添加账号…")
            guard let cli = CodexDesktop.find()?.cli else { throw SwitchError("请先安装并打开一次 Codex 桌面端，再添加账号。") }
            loginWaiting = true
            broker.status = { [weak self] in self?.phase = $0 }
            try broker.start(cli: cli, root: paths.root) { [weak self] result in
                guard let self else { return }
                defer { self.end() }
                do { let data = try result.get(); try self.store(data); self.message = "登录账号已保存；同一账号会更新原记录。当前 Codex 账号未切换。" }
                catch { self.show(error) }
            }
        } catch { end(); show(error) }
    }
    func cancelLogin() { broker.cancel(); end(); message = "已取消添加，现有账号保持不变。" }
    func confirmSwitch(_ account: SavedAccount) {
        guard !busy else { return }
        guard !demo else { message = "演示模式：点击后会先确认，再退出 Codex、切换账号并重新打开。"; return }
        guard confirm(title: "切换到「\(account.label)」？", detail: "这会退出并重新打开 Codex，正在运行的任务可能中断。请先保存工作。\n\n将同时更新共享此 CODEX_HOME 的命令行与扩展登录。请先结束其他 Codex CLI 会话。切换前会保存当前账号的最新登录状态。", button: "切换并重启") else { return }
        Task {
            do {
                try begin("读取目标账号…"); defer { end() }
                guard let target = try vault.get(account.id.uuidString) else { throw SwitchError("钥匙串中缺少这个账号，请通过「添加账号」重新登录。") }
                guard try Identity.read(target).key == account.identityKey else { throw SwitchError("保存的账号与登录资料不匹配，请重新添加。") }
                try await switchTo(target, label: account.label)
            } catch { show(error) }
        }
    }
    private func switchTo(_ target: Data, label: String) async throws {
        // Finish our isolated CLI before the desktop's helper-process shutdown check.
        // busy is already set, so neither the timer nor a manual refresh can restart it.
        if let pending = quotaTask { pending.cancel(); await pending.value }
        try SecureFile.checkFileMode(paths.config)
        guard let app = CodexDesktop.find() else { throw SwitchError("未找到 Codex 桌面端，请先安装并打开一次。") }
        _ = try Identity.read(target)
        if let live = try SecureFile.read(paths.auth), try Identity.read(live).key == Identity.read(target).key {
            try store(live); refresh(); message = "当前已是这个账号，已更新保存的登录状态。"; return
        }
        try await app.quitGracefully { phase = $0 }
        do {
            phase = "备份当前账号的最新登录状态…"
            if let live = try SecureFile.read(paths.auth) { try store(live) }
            phase = "切换登录配置并重新打开 Codex…"
            try await SwitchTransaction(authURL: paths.auth, vault: vault).replace(with: target) { try await app.launch() }
        } catch {
            // If stopping succeeded but backup/swap failed, reopen with whichever file the transaction preserved.
            if !app.running { try? await app.launch() }
            throw error
        }
        library.lastSwitch = Date(); library.rollbackAvailable = true
        do { try SecureFile.saveLibrary(library, to: paths.metadata) }
        catch { message = "已启动 Codex，但更新列表时间失败。回滚备份仍在钥匙串中。"; refresh(); return }
        refresh(); message = "已载入「\(label)」并启动 Codex。请核对 Codex 头像中的账号；过期登录会提示重新验证。"
    }
    func restore() {
        guard !demo else { message = "演示模式：这里可恢复上一次切换前的账号。"; return }
        guard !busy, confirm(title: "恢复上次切换前的账号？", detail: "这会退出并重新打开 Codex。请保存任务并结束其他 Codex CLI 会话。当前登录配置也会先备份。", button: "恢复并重启") else { return }
        Task {
            do {
                try begin("读取回滚备份…"); defer { end() }
                guard let data = try vault.get("rollback"), let original = try JSONDecoder().decode(Rollback.self, from: data).original else { throw SwitchError("暂无可恢复的登录备份。") }
                try await switchTo(original, label: "上次账号")
            } catch { show(error) }
        }
    }
    func rename(_ account: SavedAccount, label: String) {
        let name = String(label.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
        guard !name.isEmpty else { return }
        if demo { if let i = library.accounts.firstIndex(where: { $0.id == account.id }) { library.accounts[i].label = name }; return }
        do {
            try begin("更新备注…"); defer { end() }
            var next = library
            if let i = next.accounts.firstIndex(where: { $0.id == account.id }) { next.accounts[i].label = name }
            try SecureFile.saveLibrary(next, to: paths.metadata); library = next
        } catch { show(error) }
    }
    func remove(_ account: SavedAccount) {
        guard !busy, !demo else { return }
        guard confirm(title: "移除「\(account.label)」的保存记录？", detail: "只删除切换器保存的账号与钥匙串凭据。Codex 当前登录、聊天记录和订阅保持原样。上一次切换的独立回滚备份仍会保留。", button: "移除记录") else { return }
        do {
            try begin("移除保存记录…"); defer { end() }
            let previous = try vault.get(account.id.uuidString)
            try vault.remove(account.id.uuidString)
            var next = library; next.accounts.removeAll { $0.id == account.id }
            do { try SecureFile.saveLibrary(next, to: paths.metadata); library = next; quotas.removeValue(forKey: account.id) }
            catch { if let previous { try? vault.put(previous, for: account.id.uuidString) }; throw error }
            message = "保存记录已移除，Codex 当前登录保持原样。"
        } catch { show(error) }
    }
    func setAppearance(_ value: String) {
        if demo { library.appearance = value; return }
        do {
            try begin("更新外观…"); defer { end() }
            var next = library; next.appearance = value
            try SecureFile.saveLibrary(next, to: paths.metadata); library = next
        } catch { show(error) }
    }
    func openCodex() {
        guard !demo else { return }
        Task { do { guard let app = CodexDesktop.find() else { throw SwitchError("未找到 Codex 桌面端。") }; try await app.launch() } catch { show(error) } }
    }
    func refreshQuotas(accountID: UUID? = nil, automatic: Bool = false, manualWarmup: Bool = false, enabledOnly: Bool = false, forceRefresh: Bool = false, cliOverride: URL? = nil) {
        guard !busy, !refreshingQuotas, libraryReady else { return }
        guard !demo else { message = "演示额度为虚构数据，正式运行从官方服务查询。"; return }
        let now = Date()
        let targets = library.accounts.filter { (accountID == nil || $0.id == accountID) && (!enabledOnly || warmupEnabled($0)) && (forceRefresh || (quotas[$0.id] ?? QuotaState()).due(now: now, automatic: automatic)) }
        guard !targets.isEmpty else { if !automatic { message = "额度刚刚刷新过，请稍后再试。" }; return }
        refreshingQuotas = true
        quotaTask = Task { [weak self] in
            guard let self else { return }
            defer { self.refreshingQuotas = false; self.quotaTask = nil }
            let cli = cliOverride ?? CodexDesktop.find()?.cli
            for account in targets {
                if Task.isCancelled || self.busy { break }
                let old = self.quotas[account.id] ?? QuotaState()
                var loading = old; loading.loading = true; loading.attemptedAt = Date(); self.quotas[account.id] = loading
                do {
                    guard let cli else { throw SwitchError("未找到官方 CLI，请先安装并打开一次 Codex。") }
                    let auth = try self.quotaAuth(account)
                    let snapshot = try await QuotaBroker.read(cli: cli, root: self.paths.root, auth: auth, expectedKey: account.identityKey)
                    guard !Task.isCancelled else { throw CancellationError() }
                    if self.library.accounts.contains(where: { $0.id == account.id && $0.identityKey == account.identityKey }) {
                        self.quotas[account.id] = QuotaState(snapshot: snapshot, attemptedAt: Date())
                        await self.attemptWarmup(account, snapshot: snapshot, cli: cli, manual: manualWarmup)
                    }
                } catch {
                    if self.library.accounts.contains(where: { $0.id == account.id && $0.identityKey == account.identityKey }) {
                        var state = old; state.loading = false; state.attemptedAt = Date()
                        state.error = error is CancellationError ? "已取消刷新" : (error as? SwitchError)?.message ?? "查询未完成，请检查网络或登录状态。"
                        self.quotas[account.id] = state
                        if manualWarmup { self.warmupNotices[account.id] = state.error }
                        if !(error is CancellationError) { self.pauseWarmupAfterQueryFailure(account, reason: state.error ?? "额度查询未完成") }
                    }
                }
            }
            if !self.busy && !automatic && !manualWarmup { self.message = Task.isCancelled ? "已停止额度刷新，上次结果保留。" : "额度刷新结束，各账号状态见卡片。当前 Codex 未切换。" }
        }
    }
    private func quotaAuth(_ account: SavedAccount) throws -> Data {
        // Only these local reads hold the operation lock. Network requests don't block switching.
        let gate = try OperationLock(paths.root)
        return try withExtendedLifetime(gate) {
            let saved = try SecureFile.loadLibrary(paths.metadata)
            guard saved.accounts.contains(where: { $0.id == account.id && $0.identityKey == account.identityKey }) else { throw SwitchError("账号记录已变化，请刷新列表。") }
            try SecureFile.checkFileMode(paths.config)
            if let live = try SecureFile.read(paths.auth), let identity = try? Identity.read(live), identity.key == account.identityKey { return live }
            guard let data = try vault.get(account.id.uuidString) else { throw SwitchError("登录备份缺失，请重新添加账号。") }
            _ = try QuotaCredentials.read(data, expectedKey: account.identityKey)
            return data
        }
    }
    func cancelQuotaRefresh() { quotaTask?.cancel() }
    func quotaTick(visible: Bool) {
        guard visible || hasAutoWarmup else { return }
        objectWillChange.send() // Refresh reset/stale labels even when no network query is due.
        refreshQuotas(automatic: true, enabledOnly: !visible)
    }
    func pauseWarmupAfterQueryFailure(_ account: SavedAccount, reason: String) {
        guard library.accounts.first(where: { $0.id == account.id })?.warmup?.enabled == true, !busy else { return }
        do {
            let gate = try OperationLock(paths.root)
            try withExtendedLifetime(gate) {
                var next = try SecureFile.loadLibrary(paths.metadata)
                guard let i = next.accounts.firstIndex(where: { $0.id == account.id && $0.identityKey == account.identityKey }), var record = next.accounts[i].warmup, record.enabled else { return }
                record.paused = true; record.result = "自动预热已暂停 · " + reason; next.accounts[i].warmup = record
                try SecureFile.saveLibrary(next, to: paths.metadata); library = next
            }
        } catch { libraryReady = false; message = "预热暂停状态保存未完成，自动操作已停止。请检查本机数据目录。" }
    }
    func warmupStatus(_ account: SavedAccount) -> String {
        if warmingAccountID == account.id { return "正在预热 · 可停止" }
        if let notice = warmupNotices[account.id] { return notice }
        let r = account.warmup ?? WarmupRecord()
        let formatter = DateFormatter(); formatter.dateFormat = "MM-dd HH:mm"
        let stamp = r.lastAttempt.map { formatter.string(from: $0) + " · " } ?? ""
        if r.enabled && r.scheduleVersion != 2 { return "预热规则已更新，请重新开启开关确认" }
        if !r.enabled { return r.result.map { "自动关闭 · " + stamp + $0 } ?? "默认关闭 · 开启后会产生实际用量" }
        if r.paused { return stamp + (r.result ?? "已暂停，请检查后重试") }
        let next = r.nextAt.map { " · 下次不早于 " + formatter.string(from: $0) } ?? ""
        return stamp + (r.result ?? "等待首次预热") + next
    }
    func setWarmup(_ account: SavedAccount, enabled: Bool) {
        guard !busy else { return }
        if enabled && !demo && !confirm(title: "为「\(account.label)」开启自动预热？", detail: "栖言运行且电脑唤醒时，每 5 分钟检查额度。开启后首次检查会尝试发送一次「回复ok」；之后至少间隔 5 小时，并参考上次观察到的重置时间。使用 GPT-6 Luna / low。会消耗实际额度，也可能涉及账户计费；不是补充额度。\n\n仅在 7 天剩余至少 1% 时运行。不切换当前账号，不刷新或回写登录凭证。令牌过期、请求失败或结果不明会暂停。关闭窗口仍可运行，退出栖言后停止。", button: "确认开启") { return }
        do {
            if !demo { try begin("更新自动预热设置…") }
            defer { if !demo { end() } }
            guard let i = library.accounts.firstIndex(where: { $0.id == account.id }) else { return }
            var next = library; var record = next.accounts[i].warmup ?? WarmupRecord()
            record.enabled = enabled; record.paused = false; record.scheduleVersion = 2
            record.nextAt = nil // lastAttempt still enforces the minimum interval after re-enabling.
            warmupNotices.removeValue(forKey: account.id)
            next.accounts[i].warmup = record
            if !demo { try SecureFile.saveLibrary(next, to: paths.metadata) }
            library = next
            message = enabled ? "已开启该账号的自动预热，准备检查额度。" : "已关闭该账号的自动预热。"
        } catch { show(error); return }
        if enabled && !demo { refreshQuotas(accountID: account.id, automatic: true, forceRefresh: true) }
    }
    func requestWarmup(_ account: SavedAccount) {
        guard !busy, !refreshingQuotas else { return }
        guard !demo else { message = "演示模式：不会发送模型请求。"; return }
        guard confirm(title: "检查并预热「\(account.label)」一次？", detail: "确认后立即重新查询额度；即使 5 小时重置时间还没到，也会尝试发一条「回复ok」，前提是 5 小时有余额、7 天余额至少 1%。这会产生实际模型用量；若窗口已在运行，这条消息不会把窗口重新开始。\n\n如果上次结果不明，重试可能再次产生用量；成功后仍以服务端窗口时间为准。", button: "确认检查并预热") else { return }
        warmupNotices[account.id] = "正在检查额度…"
        refreshQuotas(accountID: account.id, manualWarmup: true, forceRefresh: true)
    }
    func attemptWarmup(_ account: SavedAccount, snapshot: QuotaSnapshot, cli: URL, manual: Bool) async {
        guard !Task.isCancelled, let fresh = library.accounts.first(where: { $0.id == account.id }) else { return }
        if let reason = WarmupPolicy.reason(fresh.warmup ?? WarmupRecord(), snapshot: snapshot, manual: manual) {
            if manual || reason != "等待下次预热时间" { warmupNotices[account.id] = reason }
            if manual { message = "\(account.label)：\(reason)" }; return
        }
        do {
            // Read only the chosen access token source; neither broker rotates or writes auth.
            let auth = try quotaAuth(fresh)
            try begin("正在预热「\(fresh.label)」…")
            defer { warmingAccountID = nil; end() }
            guard let i = library.accounts.firstIndex(where: { $0.id == fresh.id && $0.identityKey == fresh.identityKey }) else { return }
            var record = library.accounts[i].warmup ?? WarmupRecord()
            // Reloaded under the inter-process operation lock, so two app instances never claim together.
            if let reason = WarmupPolicy.reason(record, snapshot: snapshot, manual: manual) { warmupNotices[fresh.id] = reason; return }
            guard let reset = snapshot.fiveHours?.resetsAt else { warmupNotices[fresh.id] = "未提供 5 小时窗口，暂不预热"; return }
            let previous = record
            record.lastAttempt = Date(); record.processedReset = max(record.processedReset ?? reset, reset)
            record.paused = true // Durable pause before the turn; a crash never causes silent retries.
            record.result = "预热尝试已登记；若意外中断，请检查后手动重试"
            var next = library; next.accounts[i].warmup = record
            try SecureFile.saveLibrary(next, to: paths.metadata); library = next // Durable BEFORE any model request.
            warmingAccountID = fresh.id; warmupNotices.removeValue(forKey: fresh.id)
            do {
                let result = try await QuotaBroker.warmup(cli: cli, root: paths.root, auth: auth, expectedKey: fresh.identityKey, reset: reset)
                guard !Task.isCancelled else { throw CancellationError() }
                quotas[fresh.id] = QuotaState(snapshot: result.snapshot, attemptedAt: Date())
                if result.sent {
                    record.paused = false; record.result = result.message
                    record.nextAt = WarmupPolicy.nextAfterSuccess(attempt: record.lastAttempt!, snapshot: result.snapshot)
                    if result.confirmed { record.lastConfirmed = Date() }
                } else {
                    record = previous; record.result = result.message
                }
            } catch {
                record.paused = true
                record.result = error is CancellationError ? "已停止 · 可能已产生用量，请检查后重试" : (error as? SwitchError)?.message ?? "预热结果不明，自动请求已暂停"
            }
            next = library; next.accounts[i].warmup = record
            do { try SecureFile.saveLibrary(next, to: paths.metadata); library = next }
            catch { library = next; libraryReady = false; throw SwitchError("预热状态保存失败，已停止自动操作。请检查本机磁盘后重新打开。") }
            if record.enabled && record.scheduleVersion == 2 { warmupNotices.removeValue(forKey: fresh.id) }
            else { warmupNotices[fresh.id] = record.result }
            message = "\(fresh.label)：\(record.result ?? "已结束")"
        } catch {
            // No model turn is sent before the claim is durably saved.
            message = (error as? SwitchError)?.message ?? "预热准备未完成，请检查账号记录。"
            warmupNotices[account.id] = message
        }
    }
    private func confirm(title: String, detail: String, button: String) -> Bool {
        let alert = NSAlert(); alert.messageText = title; alert.informativeText = detail
        alert.alertStyle = .warning; alert.addButton(withTitle: button); alert.addButton(withTitle: "取消")
        alert.buttons[0].keyEquivalent = ""; alert.buttons[1].keyEquivalent = "\u{1b}"
        return alert.runModal() == .alertFirstButtonReturn
    }
}

enum DemoData {
    static var accounts: [SavedAccount] {
        [("Personal", "personal@example.com", "plus"), ("工作空间", "work@example.com", "team"), ("日常探索", "explore@example.com", "free")].enumerated().map { i, row in
            SavedAccount(id: UUID(), identityKey: "demo-\(i)", label: row.0, email: row.1, plan: row.2, savedAt: Date(), color: i)
        }
    }
}
