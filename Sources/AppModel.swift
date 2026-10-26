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
                                   email: identity.email, plan: identity.plan, savedAt: Date(), color: old?.color ?? next.accounts.count % 4)
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
    func refreshQuotas(accountID: UUID? = nil, automatic: Bool = false) {
        guard !busy, !refreshingQuotas, libraryReady else { return }
        guard !demo else { message = "演示额度为虚构数据，正式运行从官方服务查询。"; return }
        let now = Date()
        let targets = library.accounts.filter { (accountID == nil || $0.id == accountID) && (quotas[$0.id] ?? QuotaState()).due(now: now, automatic: automatic) }
        guard !targets.isEmpty else { if !automatic { message = "额度刚刚刷新过，请稍后再试。" }; return }
        refreshingQuotas = true
        quotaTask = Task { [weak self] in
            guard let self else { return }
            defer { self.refreshingQuotas = false; self.quotaTask = nil }
            let cli = CodexDesktop.find()?.cli
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
                    }
                } catch {
                    if self.library.accounts.contains(where: { $0.id == account.id && $0.identityKey == account.identityKey }) {
                        var state = old; state.loading = false; state.attemptedAt = Date()
                        state.error = error is CancellationError ? "已取消刷新" : (error as? SwitchError)?.message ?? "查询未完成，请检查网络或登录状态。"
                        self.quotas[account.id] = state
                    }
                }
            }
            if !self.busy && !automatic { self.message = Task.isCancelled ? "已停止额度刷新，上次结果保留。" : "额度刷新结束，各账号状态见卡片。当前 Codex 未切换。" }
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
        guard visible else { return }
        objectWillChange.send() // Refresh reset/stale labels even when no network query is due.
        refreshQuotas(automatic: true)
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
