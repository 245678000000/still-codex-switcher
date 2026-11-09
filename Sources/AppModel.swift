import AppKit
import SwiftUI
import Darwin
import UniformTypeIdentifiers

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
    let tokenUsage = TokenUsageController()
    @Published var quotas: [UUID: QuotaState] = [:]
    @Published private(set) var refreshingQuotas = false
    private var quotaTask: Task<Void, Never>?
    /// Accounts whose Keychain copy is newer than the auth.json Codex is still using.
    @Published var staleLive: Set<UUID> = []
    @Published var exportRequest: ExportRequest?
    private var pendingVerify: Set<UUID> = []
    @Published var authChecks: [UUID: AuthHealth] = [:]
    @Published private(set) var unlockingAccountID: UUID?
    @Published private(set) var switchingAccountID: UUID?
    private var verificationCLIOverride: URL?
    private var syncTask: Task<Void, Never>?
    private var securityObservers: [NSObjectProtocol] = []
    private var liveStamp: CredentialStamp?
    var currentHealth: AuthHealth {
        guard let active else { return .unverified(expiresAt: liveStamp?.expiresAt) }
        if staleLive.contains(active.id) { return AuthHealth.evaluate(stamp: liveStamp, verdict: active.verdict) }
        return health(active)
    }
    func unlockLogin(_ account: SavedAccount, cliOverride: URL? = nil) {
        guard !busy, unlockingAccountID == nil else { return }
        if demo { authChecks[account.id] = .checking; message = "演示：登录已解锁，正在验证"; return }
        do { try begin("正在解锁「\(account.label)」…") } catch { show(error); return }
        unlockingAccountID = account.id
        if let cliOverride { verificationCLIOverride = cliOverride }
        Task {
            defer { unlockingAccountID = nil; end() }
            do {
                try await vault.unlockAsync([account.id.uuidString])
                guard try await vault.readAsync(account.id.uuidString) != nil else { throw SwitchError("登录备份缺失，请重新登录这个账号。") }
                authChecks.removeValue(forKey: account.id)
                pendingVerify.insert(account.id); authChecks[account.id] = .checking
                message = "登录已解锁，正在验证「\(account.label)」。"
            } catch { authChecks[account.id] = error is VaultLockedError ? .locked : .unavailable; message = error.localizedDescription }
        }
    }
    func seedSwitchProgress() {
        guard demo else { return }
        switchingAccountID = library.accounts.first?.id; busy = true
        phase = "2/4 · 等待 Codex 完成退出…"
    }
    func clearCredentialCache() {
        quotaTask?.cancel(); syncTask?.cancel()
        guard let encrypted = vault as? EncryptedFileVault else { return }
        Task.detached { encrypted.clearCachedSecrets() }
    }
    private func scheduleLiveSync() {
        guard !demo, !busy, syncTask == nil, let account = active else { return }
        syncTask = Task {
            defer { syncTask = nil }
            do {
                _ = try await vault.readAsync(account.id.uuidString)
                guard !busy, !Task.isCancelled else { return }
                _ = syncLiveCredential()
            } catch {
                if error is VaultLockedError { authChecks[account.id] = .locked }
            }
        }
    }
    private var authSignature: String?
    private var authMonitor: Timer?
    /// Off for fixtures: changed logins are only re-checked automatically inside the running app.
    private var autoVerify = false
    func health(_ account: SavedAccount, now: Date = Date()) -> AuthHealth {
        let known = AuthHealth.evaluate(stamp: account.stamp, verdict: account.verdict, now: now)
        if authChecks[account.id] == .unavailable && known.isInvalid { return known }
        return authChecks[account.id] ?? known
    }
    var invalidAccounts: [SavedAccount] { library.accounts.filter { health($0).isInvalid } }
    @Published private(set) var resettingAccountID: UUID?
    @Published var resetNotices: [UUID: String] = [:]
    func useReset(_ account: SavedAccount) {
        guard !busy, !refreshingQuotas, libraryReady else { return }
        let state = quotas[account.id] ?? QuotaState()
        guard account.resetAttempt != nil || state.canStartReset() else { message = "请先刷新重置卡信息。"; return }
        let retry = account.resetAttempt != nil
        let details = retry ? "这会沿用上次请求标识核对结果；若上次尚未生效，将继续使用同一张卡。不会创建第二次消耗。" : "将为这个账号使用 1 张重置卡，恢复官方规则覆盖的额度。已使用的卡不返还，额度窗口时间可能变化。\n\n" + (state.snapshot?.resetCredits?.details() ?? "有效期待确认")
        guard confirm(title: retry ? "核对「\(account.label)」上次重置？" : "为「\(account.label)」使用 1 张重置卡？", detail: account.email + "\n\n" + details + "\n\n不切换当前 Codex 账号，不购买付费重置。", button: retry ? "核对上次请求" : "使用 1 张") else { return }
        guard !busy, !refreshingQuotas else { message = "其他操作已开始，请稍后重试。"; return }
        if demo { message = "演示确认完成 · 未消耗真实重置卡"; return }
        do { try begin("正在处理「\(account.label)」重置卡…") } catch { show(error); return }
        resettingAccountID = account.id
        Task {
            defer { self.resettingAccountID = nil; self.end() }
            do {
                guard let index = self.library.accounts.firstIndex(where: { $0.id == account.id && $0.identityKey == account.identityKey }), self.library.accounts[index].resetAttempt == account.resetAttempt else { throw SwitchError("账号或上次请求已变化，请核对列表后重试。") }
                guard let cli = CodexDesktop.find()?.cli else { throw SwitchError("请先安装并打开一次官方 Codex。") }
                try SecureFile.checkFileMode(self.paths.config)
                let auth = try await self.freshestCredentialAsync(account)
                _ = try QuotaCredentials.read(auth, expectedKey: account.identityKey)
                guard let attempt = try ResetAttempt.prepare(existing: account.resetAttempt, state: state, confirmed: true, lastResetAt: self.library.accounts[index].lastResetAt) else { return }
                var next = self.library; next.accounts[index].resetAttempt = attempt
                try SecureFile.saveLibrary(next, to: self.paths.metadata); self.library = next
                self.resetNotices[account.id] = "正在确认官方结果…"
                let outcome = try await QuotaBroker.consumeReset(cli: cli, root: self.paths.root, auth: auth, expectedKey: account.identityKey, attempt: attempt)
                // Persist the acknowledgement before allowing a new logical attempt.
                next.accounts[index].resetAttempt = nil; next.accounts[index].lastResetAt = Date()
                try SecureFile.saveLibrary(next, to: self.paths.metadata); self.library = next
                self.quotas[account.id] = QuotaState()
                self.resetNotices[account.id] = outcome.message
                do {
                    let updated = try await QuotaBroker.read(cli: cli, root: self.paths.root, auth: auth, expectedKey: account.identityKey)
                    self.quotas[account.id] = QuotaState(snapshot: updated, attemptedAt: Date())
                } catch { self.resetNotices[account.id] = outcome.message + " · 额度刷新未完成，请稍后刷新" }
                self.message = self.resetNotices[account.id] ?? outcome.message
            } catch {
                let pending = self.library.accounts.first(where: { $0.id == account.id })?.resetAttempt != nil
                self.resetNotices[account.id] = pending ? "结果待确认 · 请核对上次请求，避免重复消耗" : (error as? SwitchError)?.message ?? "重置准备未完成，请稍后重试"
                self.message = self.resetNotices[account.id] ?? "请核对重置状态"
            }
        }
    }
    @Published private(set) var warmingAccountID: UUID?
    @Published private var warmupNotices: [UUID: String] = [:]
    func warmupEnabled(_ account: SavedAccount) -> Bool { account.warmup?.enabled == true && account.warmup?.scheduleVersion == 2 }
    var hasAutoWarmup: Bool { library.accounts.contains { warmupEnabled($0) && $0.warmup?.paused != true } }

    @Published var diagnostics: [UUID: DiagnosticReport] = [:]
    @Published private(set) var diagnosingAccountID: UUID?
    private var diagnosticTask: Task<Void, Never>?
    func cancelDiagnostics() { diagnosticTask?.cancel() }
    func waitForDiagnostics() async { await diagnosticTask?.value }
    func diagnose(_ account: SavedAccount) {
        guard !busy, !refreshingQuotas, libraryReady else { return }
        if demo { seedDiagnostics(); message = "演示诊断 · 没有读取凭据或发送请求"; return }
        if let report = diagnostics[account.id], Date().timeIntervalSince(report.checkedAt) < 30 {
            message = "检查刚刚完成，请等待 30 秒后重试。"; return
        }
        guard confirm(title: "检查「\(account.label)」？", detail: "读取这个账号的本地凭据，并通过独立官方 CLI 查询额度和模型目录。不发送聊天消息，不触发自动预热，不切换或退出 Codex，也不刷新登录凭证。\n\n结果仅在本次栖言运行期间保留。模型目录可能来自缓存，不代表实际推理验证。", button: "开始基础检查") else { return }
        guard !busy, !refreshingQuotas else { message = "其他检查已开始，请稍后重试。"; return }
        do { try begin("正在检查「\(account.label)」…") } catch { show(error); return }
        diagnosingAccountID = account.id
        diagnosticTask = Task {
            defer { self.diagnosingAccountID = nil; self.diagnosticTask = nil; self.end() }
            let report: DiagnosticReport
            do {
                guard self.library.accounts.contains(where: { $0.id == account.id && $0.identityKey == account.identityKey }) else { throw SwitchError("账号记录已变化，请刷新列表后重试。") }
                guard let cli = CodexDesktop.find()?.cli else { throw SwitchError("未找到官方 CLI，请先安装并打开一次 Codex。") }
                try SecureFile.checkFileMode(self.paths.config)
                let auth = try await self.freshestCredentialAsync(account)
                _ = try QuotaCredentials.read(auth, expectedKey: account.identityKey)
                report = try await QuotaBroker.diagnose(cli: cli, root: self.paths.root, auth: auth, expectedKey: account.identityKey)
                try Task.checkCancellation()
                if report.authRejected { self.recordVerdict(account, stamp: CredentialStamp.read(auth), kind: .rejected) }
                else if report.quota != nil { self.recordVerdict(account, stamp: CredentialStamp.read(auth), kind: .accepted) }
            } catch {
                let reason = error is CancellationError ? "已取消 · 本次未发送聊天消息" : (error as? SwitchError)?.message ?? "检查未完成，请检查官方 CLI、登录备份或网络；本次没有自动重试"
                self.diagnostics[account.id] = .interrupted(reason)
                self.message = "\(account.label)：\(reason)"; return
            }
            self.diagnostics[account.id] = report
            self.message = "\(account.label)：\(report.summary)。当前 Codex 登录保持原样。"
        }
    }
    func seedDiagnostics(empty: Bool = false) {
        guard demo else { return }
        diagnostics = [:]
        if empty { return }
        let now = Date()
        for (i, account) in library.accounts.enumerated() {
            let q = QuotaSnapshot(fiveHours: QuotaWindow(remaining: i == 1 ? 0 : 76, resetsAt: now.addingTimeInterval(3600)), sevenDays: i == 2 ? nil : QuotaWindow(remaining: 42, resetsAt: now.addingTimeInterval(86400)), fetchedAt: now)
            diagnostics[account.id] = DiagnosticReport(checkedAt: now, checks: [
                DiagnosticCheck(id: "credentials", title: "账号凭据", level: .passed, detail: "本地资料与所选账号匹配；未刷新或回写凭证"),
                DiagnosticCheck(id: "service", title: "官方额度接口", level: .passed, detail: "本次额度读取成功；不代表所有模型请求均可用")
            ] + DiagnosticReport.fromQuota(q).checks + [DiagnosticCheck(id: "models", title: "模型目录", level: .passed, detail: "读取到 2 个模型标识 · 可能来自 CLI 缓存，尚未验证实际推理")], quota: q, models: ["example-model-a", "example-model-b"])
        }
    }

    private var operation: OperationLock?
    private var observer: NSObjectProtocol?
    var accounts: [SavedAccount] {
        library.accounts.filter { query.isEmpty || ($0.label + $0.email).localizedCaseInsensitiveContains(query) }
    }
    var active: SavedAccount? { library.accounts.first { $0.identityKey == current?.key } }
    var appearance: ColorScheme? { library.appearance == "dark" ? .dark : library.appearance == "light" ? .light : nil }
    init(paths: AppPaths = .live(), vault: SecretVault? = nil, demo: Bool = false) {
        self.paths = paths; self.vault = vault ?? EncryptedFileVault(directory: paths.root.appendingPathComponent("vault")); self.demo = demo
        self.updater = UpdateController(demo: demo)
        if demo {
            library.accounts = DemoData.accounts
            current = Identity(key: library.accounts[0].identityKey, email: library.accounts[0].email, plan: "plus")
            message = "界面演示 · 使用虚构账号，不读取或切换真实登录状态。"
            let now = Date()
            quotas[library.accounts[0].id] = QuotaState(snapshot: QuotaSnapshot(fiveHours: QuotaWindow(remaining: 76, resetsAt: now.addingTimeInterval(10800)), sevenDays: QuotaWindow(remaining: 42, resetsAt: now.addingTimeInterval(345600)), fetchedAt: now))
            quotas[library.accounts[1].id] = QuotaState(snapshot: QuotaSnapshot(fiveHours: QuotaWindow(remaining: 18, resetsAt: now.addingTimeInterval(2400)), sevenDays: QuotaWindow(remaining: 8, resetsAt: now.addingTimeInterval(86400)), fetchedAt: now))
            seedResetCards()
            // Fictional auth states: valid, access token expired, rejected by the service.
            for i in library.accounts.indices {
                let fingerprint = "demo-\(i)"
                library.accounts[i].stamp = CredentialStamp(fingerprint: fingerprint, issuedAt: now.addingTimeInterval(-86400 * 3), expiresAt: now.addingTimeInterval(i == 1 ? -5400 : 86400 * 6))
                library.accounts[i].verdict = AuthVerdict(kind: i == 2 ? .rejected : .accepted, fingerprint: fingerprint, at: now.addingTimeInterval(i == 1 ? -9000 : -600))
            }
            if library.accounts.count > 2 { quotas[library.accounts[2].id] = QuotaState(error: AuthRejectedError().message, attemptedAt: now) }
            return
        }
        do { library = try SecureFile.loadLibrary(paths.metadata) }
        catch { libraryReady = false; errorText = "账号列表读取异常，原文件已保留。请检查本地数据目录。" }
        refresh()
        // Detect account changes after the user logs in through Codex itself.
        observer = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in guard let self, !self.busy else { return }; self.refresh(); self.scheduleLiveSync() }
        }
    }
    /// Watches Codex's auth.json (a cheap stat every 2 s). Called by the app, not by fixtures.
    func startAuthMonitor() {
        guard !demo, authMonitor == nil else { return }
        autoVerify = true
        authSignature = Self.fileSignature(paths.auth)
        scheduleLiveSync()
        for name in [NSWorkspace.screensDidSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            securityObservers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.clearCredentialCache() }
            })
        }
        securityObservers.append(DistributedNotificationCenter.default().addObserver(forName: NSNotification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.clearCredentialCache() }
        })
        authMonitor = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.authMonitorTick() }
        }
    }
    func stopAuthMonitor() {
        authMonitor?.invalidate(); authMonitor = nil; clearCredentialCache()
        for observer in securityObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer); DistributedNotificationCenter.default().removeObserver(observer) }
        securityObservers.removeAll()
    }
    private func authMonitorTick() {
        let signature = Self.fileSignature(paths.auth)
        guard signature != authSignature, !busy else { return }
        authSignature = signature
        refresh()
        scheduleLiveSync()
    }
    nonisolated static func fileSignature(_ url: URL) -> String? {
        var s = stat()
        guard lstat(url.path, &s) == 0 else { return nil }
        return "\(s.st_ino):\(s.st_size):\(s.st_mtimespec.tv_sec):\(s.st_mtimespec.tv_nsec)"
    }
    /// Copies a login that Codex renewed or re-created into the Keychain, never over a clearly newer copy.
    /// Only updates accounts that are already saved; it never adds one on its own.
    @discardableResult func syncLiveCredential(verify: Bool = true) -> StoreOutcome? {
        guard !demo, libraryReady, !busy else { return nil }
        do {
            try SecureFile.checkFileMode(paths.config)
            guard let live = try SecureFile.read(paths.auth), let identity = try? Identity.read(live),
                  library.accounts.contains(where: { $0.identityKey == identity.key }) else { return nil }
            let gate = try OperationLock(paths.root)
            let result: StoreOutcome? = try withExtendedLifetime(gate) { () throws -> StoreOutcome? in
                library = try SecureFile.loadLibrary(paths.metadata)
                guard library.accounts.contains(where: { $0.identityKey == identity.key }) else { return nil }
                return try store(live, source: .codex, policy: .keepNewer)
            }
            guard let outcome = result else { return nil }
            switch outcome {
            case .keptNewer(let id): staleLive.insert(id)
            case .unchanged(let id): staleLive.remove(id)
            case .added(let id), .updated(let id):
                staleLive.remove(id)
                if verify { verifySoon(id) }
            }
            return outcome
        } catch { return nil }
    }
    /// Re-checks a changed login with the official service as soon as no other work is running.
    func verifySoon(_ id: UUID, cliOverride: URL? = nil) {
        guard !demo else { return }
        if let cliOverride { verificationCLIOverride = cliOverride }
        pendingVerify.insert(id); authChecks[id] = .checking
        // Re-login has priority over a background sweep; cancellation only stops our private child.
        quotaTask?.cancel()
        runPendingVerification()
    }
    private func runPendingVerification() {
        guard (autoVerify || verificationCLIOverride != nil), !busy, !refreshingQuotas, libraryReady, !pendingVerify.isEmpty else { return }
        let ids = pendingVerify; pendingVerify = []
        let cli = verificationCLIOverride; verificationCLIOverride = nil
        refreshQuotas(only: ids, automatic: true, forceRefresh: true, cliOverride: cli, verificationOnly: true)
    }
    /// Remembers the service's answer for the exact copy that was sent (matched by fingerprint).
    func recordVerdict(_ account: SavedAccount, stamp: CredentialStamp?, kind: AuthVerdict.Kind) {
        guard let stamp, let index = library.accounts.firstIndex(where: { $0.id == account.id && $0.identityKey == account.identityKey }) else { return }
        let entry = library.accounts[index]
        // A verdict for an older copy must not mark a newer saved login as valid or invalid.
        guard entry.stamp == nil || entry.stamp?.fingerprint == stamp.fingerprint else { return }
        authChecks.removeValue(forKey: account.id)
        if entry.stamp != nil, entry.verdict?.kind == kind, entry.verdict?.fingerprint == stamp.fingerprint { return }
        let verdict = AuthVerdict(kind: kind, fingerprint: stamp.fingerprint, at: Date())
        let saved = updateMetadata(account) { item in
            guard item.stamp == nil || item.stamp?.fingerprint == stamp.fingerprint else { return }
            item.stamp = stamp; item.verdict = verdict
        }
        if !saved { library.accounts[index].stamp = stamp; library.accounts[index].verdict = verdict }
    }
    /// Small metadata change under the inter-process lock, without marking the whole UI busy.
    @discardableResult private func updateMetadata(_ account: SavedAccount, _ change: (inout SavedAccount) -> Void) -> Bool {
        guard !demo, libraryReady else { return false }
        do {
            if operation != nil {
                // Inside begin()/end() this process already holds the lock and the in-memory list was just reloaded.
                guard let i = library.accounts.firstIndex(where: { $0.id == account.id && $0.identityKey == account.identityKey }) else { return false }
                var next = library; change(&next.accounts[i])
                try SecureFile.saveLibrary(next, to: paths.metadata); library = next
                return true
            }
            let gate = try OperationLock(paths.root)
            return try withExtendedLifetime(gate) { () throws -> Bool in
                var next = try SecureFile.loadLibrary(paths.metadata)
                guard let i = next.accounts.firstIndex(where: { $0.id == account.id && $0.identityKey == account.identityKey }) else { return false }
                change(&next.accounts[i])
                try SecureFile.saveLibrary(next, to: paths.metadata); library = next
                return true
            }
        } catch { return false }
    }
    /// The newest local copy of an account's login: Codex's live file when it is this account
    /// and not older than the Keychain copy; otherwise the Keychain copy.
    func freshestCredential(_ account: SavedAccount) throws -> Data {
        let saved = try vault.get(account.id.uuidString)
        if let live = try SecureFile.read(paths.auth), let identity = try? Identity.read(live), identity.key == account.identityKey {
            if let saved, CredentialStamp.read(live)?.isOlder(than: CredentialStamp.read(saved)) == true { return saved }
            return live
        }
        guard let saved else { throw SwitchError("登录备份缺失，请重新登录这个账号。") }
        _ = try QuotaCredentials.read(saved, expectedKey: account.identityKey)
        return saved
    }
    func refresh() {
        guard !demo else { return }
        desktop = CodexDesktop.find()
        do {
            try SecureFile.checkFileMode(paths.config)
            let data = try SecureFile.read(paths.auth)
            current = try data.map(Identity.read); liveStamp = data.flatMap(CredentialStamp.read)
        } catch { current = nil; message = error.localizedDescription }
    }
    func show(_ error: Error) {
        if error is VaultLockedError {
            for account in library.accounts { authChecks[account.id] = .locked }
            message = error.localizedDescription
        } else { errorText = error.localizedDescription }
    }
    private func begin(_ text: String) throws {
        guard !busy, libraryReady else { throw SwitchError("请先完成当前操作并检查账号列表。") }
        operation = try OperationLock(paths.root)
        // Reload while holding the inter-process lock; another switcher may have updated it.
        do { library = try SecureFile.loadLibrary(paths.metadata) }
        catch { operation = nil; throw error }
        busy = true; phase = text; message = ""
    }
    private func end() {
        switchingAccountID = nil
        busy = false; loginWaiting = false; phase = ""; operation = nil
        runPendingVerification()
    }
    /// Saves one login copy to the Keychain and the account list. Callers hold the operation lock.
    /// `.keepNewer` never lets an older copy (for example a stale auth.json) replace a fresher login.
    @discardableResult
    func store(_ data: Data, source: CredentialSource, policy: StorePolicy = .replace, label: String? = nil) throws -> StoreOutcome {
        let identity = try Identity.read(data)
        var next = library
        let existing = next.accounts.firstIndex { $0.identityKey == identity.key }
        let id = existing.map { next.accounts[$0].id } ?? UUID()
        let key = id.uuidString
        let previous = try vault.get(key)
        let stamp = CredentialStamp.read(data)
        if let previous, let index = existing {
            if previous == data {
                // Same bytes: only backfill the stamp for lists saved by older versions.
                if next.accounts[index].stamp == nil, let stamp {
                    next.accounts[index].stamp = stamp
                    try SecureFile.saveLibrary(next, to: paths.metadata); library = next
                }
                return .unchanged(id)
            }
            if policy == .keepNewer, stamp?.isOlder(than: CredentialStamp.read(previous)) == true { return .keptNewer(id) }
        }
        let old = existing.map { next.accounts[$0] }
        let account = SavedAccount(id: id, identityKey: identity.key, label: old?.label ?? label ?? CredentialTransfer.defaultLabel(identity.email),
                                   email: identity.email, plan: identity.plan, savedAt: Date(), color: old?.color ?? next.accounts.count % 4,
                                   warmup: old?.warmup, resetAttempt: old?.resetAttempt, lastResetAt: old?.lastResetAt,
                                   stamp: stamp, verdict: old?.verdict, credentialSource: source.rawValue, credentialUpdatedAt: Date())
        if let existing { next.accounts[existing] = account } else { next.accounts.append(account) }
        try vault.put(data, for: key)
        do { try SecureFile.saveLibrary(next, to: paths.metadata); library = next }
        catch {
            if let previous { try? vault.put(previous, for: key) } else { try? vault.remove(key) }
            throw SwitchError("保存账号列表未完成，登录文件保持不变。请检查本地磁盘空间。")
        }
        // The old verdict belonged to the previous copy; drop its error and let the new copy be checked.
        quotas[id] = QuotaState(); authChecks.removeValue(forKey: id)
        return existing == nil ? .added(id) : .updated(id)
    }
    func saveCurrent() {
        guard !demo else { message = "演示模式：正式版点击这里会保存当前 Codex 登录状态。"; return }
        do {
            try begin("保存当前账号…"); defer { end() }
            try SecureFile.checkFileMode(paths.config)
            guard let data = try SecureFile.read(paths.auth) else { throw SwitchError("请先在 Codex 里登录一次，再保存当前账号。") }
            let outcome = try store(data, source: .codex, policy: .keepNewer); refresh()
            switch outcome {
            case .keptNewer(let id):
                staleLive.insert(id)
                message = "钥匙串里已有这个账号更新的登录（例如刚重新登录过），已保留较新的那份。需要时在卡片上点「载入新登录」。"
            case .unchanged(let id):
                staleLive.remove(id); message = "保存的登录已是 Codex 当前使用的这一份。"
            case .added(let id), .updated(let id):
                staleLive.remove(id); pendingVerify.insert(id)
                message = "当前账号已保存到本机钥匙串。以后可直接点击切换。"
            }
        } catch { show(error) }
    }
    func addAccount() { beginLogin(for: nil) }
    /// Official browser login for an account whose saved login stopped working.
    func reauthorize(_ account: SavedAccount) { beginLogin(for: account) }
    private func beginLogin(for target: SavedAccount?) {
        guard !busy else { return }
        guard !demo else {
            message = target.map { "演示模式：正式版会打开官方登录页，重新登录「\($0.label)」。" } ?? "演示模式：正式版会在浏览器打开官方登录，保留当前 Codex 账号。"
            return
        }
        do { try begin(target.map { "准备重新登录「\($0.label)」…" } ?? "准备添加账号…") }
        catch { show(error); return }
        Task {
        do {
            try await vault.unlockAsync(target.map { [$0.id.uuidString] } ?? [])
            guard let cli = CodexDesktop.find()?.cli else { throw SwitchError("请先安装并打开一次 Codex 桌面端，再添加账号。") }
            loginWaiting = true
            broker.status = { [weak self] text in
                guard let self else { return }
                self.phase = target.map { text + "（请选择 \($0.email)）" } ?? text
            }
            try broker.start(cli: cli, root: paths.root) { [weak self] result in
                guard let self else { return }
                self.loginWaiting = false; self.phase = "正在保存新登录…"
                Task {
                var verify: UUID?
                var reload: SavedAccount?
                do {
                    let data = try result.get()
                    let identity = try Identity.read(data)
                    if let target, identity.key != target.identityKey {
                        guard self.confirm(title: "登录的不是「\(target.label)」", detail: "浏览器里登录的是 \(identity.email)，要重新登录的是 \(target.email)。\n\n可以把这次登录另存为账号；或者取消，再用正确的账号重新登录。", button: "另存为账号") else {
                            self.end(); self.message = "未保存这次登录，「\(target.label)」保持原样。"; return
                        }
                    }
                    try await self.vault.unlockAsync(target.map { [$0.id.uuidString] } ?? [])
                    let outcome = try self.store(data, source: .login, policy: .replace)
                    let saved = self.library.accounts.first { $0.id == outcome.id }
                    verify = outcome.id
                    if let saved, identity.key == self.current?.key, outcome.changed {
                        // Codex keeps the old file until it restarts with the new one.
                        self.staleLive.insert(saved.id); reload = saved
                    }
                    switch outcome {
                    case .added: self.message = "新账号已保存，正在验证认证状态。当前 Codex 账号未切换。"
                    case .updated: self.message = "已更新「\(saved?.label ?? identity.email)」的登录，正在重新验证。"
                    case .unchanged, .keptNewer: self.message = "这次登录与已保存的一致。"
                    }
                } catch { self.show(error) }
                if let verify { self.verifySoon(verify) }
                self.end()
                if let reload { self.staleLive.insert(reload.id) }
                }
            }
        } catch { end(); show(error) }
        }
    }
    /// Replaces the auth.json Codex is using with the newer saved copy of the same account, then restarts Codex.
    func reloadActive(_ account: SavedAccount, confirmFirst: Bool = true) {
        guard !busy else { return }
        guard !demo else { message = "演示模式：正式版会重启 Codex 并载入新登录。"; return }
        if confirmFirst && !confirm(title: "把新登录载入 Codex？", detail: "这会退出并重新打开 Codex，用保存的新登录替换 Codex 正在使用的旧登录。请先保存正在进行的任务，并结束其他 Codex 命令行会话。", button: "载入并重启") { return }
        Task {
            do {
                try begin("1/4 · 准备载入「\(account.label)」的新登录…"); defer { end() }
                switchingAccountID = account.id; quotaTask?.cancel()
                await Task.yield()
                guard let target = try await vault.readAsync(account.id.uuidString), try Identity.read(target).key == account.identityKey else {
                    throw SwitchError("钥匙串中缺少这个账号的登录，请重新登录。")
                }
                try await switchTo(target, label: account.label, reload: true)
            } catch { show(error) }
        }
    }
    func cancelLogin() { broker.cancel(); end(); message = "已取消添加，现有账号保持不变。" }
    func confirmSwitch(_ account: SavedAccount) {
        guard !busy else { return }
        guard !demo else { message = "演示模式：点击后会先确认，再退出 Codex、切换账号并重新打开。"; return }
        let warning: String
        switch health(account) {
        case .invalid: warning = "\n\n⚠️ 这个账号的认证已失效，切换后 Codex 很可能要求重新登录。建议先点「重新登录」。"
        case .expired: warning = "\n\n访问令牌已过期：Codex 启动后会尝试用刷新令牌续期；若提示登录，请回到这里点「重新登录」。"
        default: warning = ""
        }
        guard confirm(title: "切换到「\(account.label)」？", detail: "这会退出并重新打开 Codex，正在运行的任务可能中断。请先保存工作。\n\n将同时更新共享此 CODEX_HOME 的命令行与扩展登录。请先结束其他 Codex CLI 会话。切换前会保存当前账号的最新登录状态。" + warning, button: "切换并重启") else { return }
        Task {
            do {
                try begin("1/4 · 准备切换至「\(account.label)」…"); defer { end() }
                switchingAccountID = account.id; quotaTask?.cancel()
                await Task.yield()
                guard let target = try await vault.readAsync(account.id.uuidString) else { throw SwitchError("钥匙串中缺少这个账号，请通过「添加账号」重新登录。") }
                guard try Identity.read(target).key == account.identityKey else { throw SwitchError("保存的账号与登录资料不匹配，请重新添加。") }
                try await switchTo(target, label: account.label)
            } catch { show(error) }
        }
    }
    /// `reload` replaces Codex's file even when it already holds this account (a newer saved login).
    private func switchTo(_ target: Data, label: String, reload: Bool = false) async throws {
        // Finish our isolated CLI before the desktop's helper-process shutdown check.
        // busy is already set, so neither the timer nor a manual refresh can restart it.
        if let pending = quotaTask { pending.cancel(); await pending.value }
        try SecureFile.checkFileMode(paths.config)
        guard let app = CodexDesktop.find() else { throw SwitchError("未找到 Codex 桌面端，请先安装并打开一次。") }
        let targetKey = try Identity.read(target).key
        let targetID = library.accounts.first { $0.identityKey == targetKey }?.id
        if let live = try SecureFile.read(paths.auth), try Identity.read(live).key == targetKey {
            if live == target {
                if let targetID { staleLive.remove(targetID) }
                refresh(); message = "Codex 已在使用这份登录，无需重启。"; return
            }
            let targetIsNewer = CredentialStamp.read(live)?.isOlder(than: CredentialStamp.read(target)) == true
            if !(reload || targetIsNewer) {
                // Same account and Codex's copy is not older: keep Codex's copy instead of restarting.
                let outcome = try store(live, source: .codex, policy: .keepNewer)
                if case .keptNewer = outcome { staleLive.insert(outcome.id) } else { staleLive.remove(outcome.id) }
                refresh(); message = "当前已是这个账号，已更新保存的登录状态。"; return
            }
        }
        // Resolve any legacy access requirement before asking the desktop to quit.
        if let active, active.identityKey != targetKey { _ = try await vault.readAsync(active.id.uuidString) }
        try await app.quitGracefully { phase = "2/4 · " + $0 }
        do {
            phase = "3/4 · 保存可回滚的登录备份…"
            // Never back up a stale copy of the target over the newer login we are about to load.
            // The rollback item below still keeps the exact file that is being replaced.
            if let live = try SecureFile.read(paths.auth), (try? Identity.read(live).key) != targetKey {
                let outcome = try store(live, source: .codex, policy: .keepNewer)
                if case .keptNewer = outcome { staleLive.insert(outcome.id) }
            }
            phase = "4/4 · 载入「\(label)」并启动 Codex…"
            try await SwitchTransaction(authURL: paths.auth, vault: vault).replace(with: target) { try await app.launch() }
        } catch {
            // If stopping succeeded but backup/swap failed, reopen with whichever file the transaction preserved.
            if !app.running { try? await app.launch() }
            throw error
        }
        if let targetID { staleLive.remove(targetID) }
        library.lastSwitch = Date(); library.rollbackAvailable = true
        do { try SecureFile.saveLibrary(library, to: paths.metadata) }
        catch { message = "已启动 Codex，但更新列表时间失败。回滚备份仍在钥匙串中。"; refresh(); return }
        refresh(); message = reload ? "已把「\(label)」的新登录载入 Codex。请在 Codex 头像中核对账号。" : "已载入「\(label)」并启动 Codex。请核对 Codex 头像中的账号；过期登录会提示重新验证。"
        if let targetID { pendingVerify.insert(targetID) }
    }
    func restore() {
        guard !demo else { message = "演示模式：这里可恢复上一次切换前的账号。"; return }
        guard !busy, confirm(title: "恢复上次切换前的账号？", detail: "这会退出并重新打开 Codex。请保存任务并结束其他 Codex CLI 会话。当前登录配置也会先备份。", button: "恢复并重启") else { return }
        Task {
            do {
                try begin("读取回滚备份…"); defer { end() }
                guard let data = try await vault.readAsync("rollback"), let original = try JSONDecoder().decode(Rollback.self, from: data).original else { throw SwitchError("暂无可恢复的登录备份。") }
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
            guard library.accounts.first(where: { $0.id == account.id })?.resetAttempt == nil else { throw SwitchError("请先核对上次重置请求，再移除账号，保留防重复扣卡记录。") }
            let previous = try vault.get(account.id.uuidString)
            try vault.remove(account.id.uuidString)
            var next = library; next.accounts.removeAll { $0.id == account.id }
            do { try SecureFile.saveLibrary(next, to: paths.metadata); library = next; quotas.removeValue(forKey: account.id); diagnostics.removeValue(forKey: account.id); staleLive.remove(account.id) }
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
    func refreshQuotas(accountID: UUID? = nil, only: Set<UUID>? = nil, automatic: Bool = false, manualWarmup: Bool = false, enabledOnly: Bool = false, forceRefresh: Bool = false, cliOverride: URL? = nil, verificationOnly: Bool = false) {
        guard !busy, !refreshingQuotas, libraryReady else { return }
        guard !demo else { message = "演示额度为虚构数据，正式运行从官方服务查询。"; return }
        let now = Date()
        let targets = library.accounts.filter { (accountID == nil || $0.id == accountID) && (only?.contains($0.id) ?? true) && (!enabledOnly || warmupEnabled($0)) && (forceRefresh || (quotas[$0.id] ?? QuotaState()).due(now: now, automatic: automatic)) }
        guard !targets.isEmpty else { if !automatic { message = "额度刚刚刷新过，请稍后再试。" }; return }
        refreshingQuotas = true
        quotaTask = Task { [weak self] in
            guard let self else { return }
            defer {
                // A cancelled priority batch must not leave unvisited cards spinning forever.
                if verificationOnly {
                    for account in targets where self.authChecks[account.id] == .checking && !self.pendingVerify.contains(account.id) {
                        self.authChecks.removeValue(forKey: account.id)
                    }
                }
                self.refreshingQuotas = false; self.quotaTask = nil; self.runPendingVerification()
            }
            let cli = cliOverride ?? CodexDesktop.find()?.cli
            for account in targets {
                if Task.isCancelled || self.busy { break }
                let old = self.quotas[account.id] ?? QuotaState()
                var loading = old; loading.loading = true; loading.attemptedAt = Date(); self.quotas[account.id] = loading
                var used: CredentialStamp?
                do {
                    guard let cli else { throw SwitchError("未找到官方 CLI，请先安装并打开一次 Codex。") }
                    let auth = try await self.quotaAuthAsync(account)
                    used = CredentialStamp.read(auth)
                    let snapshot = try await QuotaBroker.read(cli: cli, root: self.paths.root, auth: auth, expectedKey: account.identityKey)
                    guard !Task.isCancelled else { throw CancellationError() }
                    if self.library.accounts.contains(where: { $0.id == account.id && $0.identityKey == account.identityKey && ($0.stamp == nil || $0.stamp?.fingerprint == used?.fingerprint) }) {
                        self.quotas[account.id] = QuotaState(snapshot: snapshot, attemptedAt: Date())
                        self.recordVerdict(account, stamp: used, kind: .accepted)
                        if verificationOnly {
                            self.message = "「\(account.label)」认证有效，登录验证完成。" + (self.staleLive.contains(account.id) ? " Codex 仍用旧登录，可点击「载入新登录」。" : "")
                        } else { await self.attemptWarmup(account, snapshot: snapshot, cli: cli, manual: manualWarmup) }
                    }
                } catch {
                    if self.library.accounts.contains(where: { $0.id == account.id && $0.identityKey == account.identityKey }) {
                        // Ignore callbacks for a login replaced while the request was in flight.
                        let currentStamp = self.library.accounts.first { $0.id == account.id }?.stamp
                        if let used, let currentStamp, currentStamp.fingerprint != used.fingerprint { continue }
                        if error is AuthRejectedError { self.recordVerdict(account, stamp: used, kind: .rejected) }
                        else if error is VaultLockedError { self.authChecks[account.id] = .locked }
                        else if !(error is CancellationError) { self.authChecks[account.id] = .unavailable }
                        else if !self.pendingVerify.contains(account.id) { self.authChecks.removeValue(forKey: account.id) }
                        if verificationOnly && !(error is CancellationError) { self.message = "「\(account.label)」验证未完成：" + error.localizedDescription }
                        var state = old; state.loading = false; state.attemptedAt = Date()
                        state.error = error is CancellationError ? "已取消刷新" : (error as? SwitchError)?.message ?? (error as? AuthRejectedError)?.message ?? (error as? VaultLockedError)?.errorDescription ?? "查询未完成，请检查网络或登录状态。"
                        self.quotas[account.id] = state
                        if manualWarmup { self.warmupNotices[account.id] = state.error }
                        if !(error is CancellationError) && !(error is VaultLockedError) && !verificationOnly { self.pauseWarmupAfterQueryFailure(account, reason: state.error ?? "额度查询未完成") }
                    }
                }
            }
            if !self.busy && !automatic && !manualWarmup && !verificationOnly { self.message = Task.isCancelled ? "已停止额度刷新，上次结果保留。" : "额度刷新结束，各账号状态见卡片。当前 Codex 未切换。" }
        }
    }
    func freshestCredentialAsync(_ account: SavedAccount) async throws -> Data {
        let saved = try await vault.readAsync(account.id.uuidString)
        let url = paths.auth
        let live = try await Task.detached { try SecureFile.read(url) }.value
        try Task.checkCancellation()
        if let live, let identity = try? Identity.read(live), identity.key == account.identityKey {
            if let saved, CredentialStamp.read(live)?.isOlder(than: CredentialStamp.read(saved)) == true { return saved }
            return live
        }
        guard let saved else { throw SwitchError("登录备份缺失，请重新登录这个账号。") }
        _ = try QuotaCredentials.read(saved, expectedKey: account.identityKey)
        return saved
    }
    private func quotaAuthAsync(_ account: SavedAccount) async throws -> Data {
        let paths = paths; let vault = vault
        try Task.checkCancellation()
        let result = try await Task.detached(priority: .utility) {
            let gate = try OperationLock(paths.root)
            return try withExtendedLifetime(gate) {
                let library = try SecureFile.loadLibrary(paths.metadata)
                guard let savedAccount = library.accounts.first(where: { $0.id == account.id && $0.identityKey == account.identityKey }) else { throw SwitchError("账号记录已变化，请刷新列表。") }
                try SecureFile.checkFileMode(paths.config)
                let live = try SecureFile.read(paths.auth)
                // The matching live file needs no vault authorization when it is the same/newer copy.
                if let live, (try? Identity.read(live).key) == account.identityKey,
                   let stamp = CredentialStamp.read(live), let savedStamp = savedAccount.stamp,
                   stamp.fingerprint == savedStamp.fingerprint || (stamp.issuedAt != nil && savedStamp.issuedAt != nil && !stamp.isOlder(than: savedStamp)) { return live }
                let saved = try vault.get(account.id.uuidString)
                if let live, (try? Identity.read(live).key) == account.identityKey,
                   saved == nil || CredentialStamp.read(live)?.isOlder(than: saved.flatMap(CredentialStamp.read)) != true { return live }
                guard let saved else { throw SwitchError("登录备份缺失，请重新登录这个账号。") }
                _ = try QuotaCredentials.read(saved, expectedKey: account.identityKey)
                return saved
            }
        }.value
        try Task.checkCancellation(); return result
    }
    func cancelQuotaRefresh() { quotaTask?.cancel() }
    func waitForQuotaRefresh() async {
        while let task = quotaTask { await task.value }
    }
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
            let auth = try await quotaAuthAsync(fresh)
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
                if error is AuthRejectedError { recordVerdict(fresh, stamp: CredentialStamp.read(auth), kind: .rejected) }
                record.result = error is CancellationError ? "已停止 · 可能已产生用量，请检查后重试" : (error as? SwitchError)?.message ?? (error as? AuthRejectedError)?.message ?? "预热结果不明，自动请求已暂停"
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
    // MARK: Export / import

    func requestExport(_ only: SavedAccount? = nil) {
        guard !busy else { return }
        guard libraryReady, !library.accounts.isEmpty else { message = "还没有可以导出的账号。"; return }
        let all = Set(library.accounts.map(\.id))
        exportRequest = ExportRequest(selected: only.map { Set([$0.id]) } ?? all)
    }
    func export(_ ids: Set<UUID>, password: String) {
        guard !busy, libraryReady else { return }
        if demo { message = "演示模式：不会读取或导出真实登录。"; return }
        syncLiveCredential(verify: false)
        let chosen = library.accounts.filter { ids.contains($0.id) }
        guard !chosen.isEmpty else { message = "请至少选择一个账号。"; return }
        let panel = NSSavePanel()
        let day = DateFormatter(); day.dateFormat = "yyyyMMdd"
        panel.nameFieldStringValue = "栖言账号-\(day.string(from: Date())).\(CredentialTransfer.fileExtension)"
        panel.allowedContentTypes = [CredentialTransfer.fileType]
        panel.canCreateDirectories = true
        panel.message = "文件用你设置的密码加密。请把文件和密码分开发送。"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try begin("正在读取 \(chosen.count) 个账号的登录…") } catch { show(error); return }
        Task {
            defer { self.end() }
            do {
                var items: [TransferAccount] = []
                for account in chosen {
                    guard let fresh = self.library.accounts.first(where: { $0.id == account.id && $0.identityKey == account.identityKey }) else { continue }
                    let data = try await self.freshestCredentialAsync(fresh)
                    _ = try QuotaCredentials.read(data, expectedKey: fresh.identityKey)
                    items.append(TransferAccount(label: fresh.label, email: fresh.email, plan: fresh.plan, auth: data))
                }
                self.phase = "正在加密 \(items.count) 个账号…"
                let snapshot = items
                let app = "still-codex-switcher-macos/" + AppRelease.current
                let sealed = try await Task.detached(priority: .userInitiated) { try CredentialTransfer.seal(snapshot, password: password, app: app) }.value
                try SecureFile.write(sealed, to: url)
                self.message = "已导出 \(snapshot.count) 个账号到「\(url.lastPathComponent)」。文件和密码请分开发送。"
            } catch { self.show(error) }
        }
    }
    func importAccounts() {
        guard !busy else { return }
        guard libraryReady else { message = "账号列表异常，暂不能导入。"; return }
        if demo { message = "演示模式：不会读取文件或写入登录。"; return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [CredentialTransfer.fileType, .json]
        panel.allowsMultipleSelection = false; panel.canChooseDirectories = false
        panel.message = "选择栖言导出的 .stillcodex 文件，或另一台电脑上 Codex 的 auth.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do {
                guard let raw = try SecureFile.read(url) else { throw SwitchError("没有找到这个文件。") }
                let incoming: [TransferAccount]
                if CredentialTransfer.isEnvelope(raw) {
                    guard let password = self.askPassword(title: "输入导出密码", detail: "「\(url.lastPathComponent)」已加密，请输入导出时设置的密码。") else { return }
                    self.message = "正在解密…"
                    incoming = try await Task.detached(priority: .userInitiated) { try CredentialTransfer.open(raw, password: password) }.value
                } else {
                    incoming = [try CredentialTransfer.fromAuthFile(raw)]
                }
                self.applyImport(incoming, source: url.lastPathComponent)
            } catch { self.message = ""; self.show(error) }
        }
    }
    /// Shows what will change, then writes only the Keychain copies. Codex's own auth.json is never touched.
    func applyImport(_ incoming: [TransferAccount], source: String, confirmFirst: Bool = true) {
        guard !busy, libraryReady else { return }
        do {
            let plan = try CredentialTransfer.plan(incoming, library: library) { try self.vault.get($0.id.uuidString) }
            let actionable = plan.filter { $0.action == .add || $0.action == .update }
            guard !actionable.isEmpty else {
                message = "「\(source)」里的 \(plan.count) 个账号本机都已是同一份或更新的登录，无需导入。"; return
            }
            let lines = plan.map { (item) -> String in
                let name = item.existing?.label ?? item.account.label
                switch item.action {
                case .add: return "＋ 新增　\(name)（\(item.identity.email)）"
                case .update: return "↻ 更新登录　\(name)" + (item.identity.key == current?.key ? " · 正在使用，需载入后生效" : "")
                case .same: return "＝ 已是同一份　\(name)"
                case .olderThanSaved: return "－ 跳过　\(name) · 本机已有更新的登录"
                }
            }
            if confirmFirst {
                guard confirm(title: "从「\(source)」导入 \(actionable.count) 个账号？", detail: lines.joined(separator: "\n") + "\n\n只写入栖言保存的登录（钥匙串），不改动 Codex 当前登录。\n\n导入的是原设备的同一份登录：两台设备都在用时，先续期的一方会让另一方失效（Codex 提示 refresh token was already used），需要重新登录。", button: "导入") else { return }
            }
            try begin("正在导入…")
            defer { end() }
            var changed: [UUID] = []
            var needsReload = false
            for item in actionable {
                let outcome = try store(item.account.auth, source: .imported, policy: .keepNewer, label: item.account.label)
                guard outcome.changed else { continue }
                changed.append(outcome.id)
                if item.identity.key == current?.key { staleLive.insert(outcome.id); needsReload = true }
            }
            pendingVerify.formUnion(changed)
            message = "已导入 \(changed.count) 个账号，正在逐个验证认证状态。" + (needsReload ? "正在使用的账号需在卡片上点「载入新登录」后生效。" : "")
        } catch { show(error) }
    }
    private func askPassword(title: String, detail: String) -> String? {
        let alert = NSAlert(); alert.messageText = title; alert.informativeText = detail
        alert.addButton(withTitle: "解密"); alert.addButton(withTitle: "取消")
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = "导出密码"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let value = field.stringValue
        return value.isEmpty ? nil : value
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
