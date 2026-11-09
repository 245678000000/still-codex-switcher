import SwiftUI

struct ExportRequest: Identifiable {
    let id = UUID()
    var selected: Set<UUID>
}

extension AuthHealth.Tone {
    var ink: Color {
        switch self {
        case .good: return Palette.accent
        case .neutral: return Palette.muted
        case .warning: return Palette.warning
        case .danger: return Palette.danger
        }
    }
    var wash: Color {
        switch self {
        case .good: return Palette.accentWash
        case .neutral: return Palette.sidebar
        case .warning: return Palette.warningWash
        case .danger: return Palette.dangerWash
        }
    }
}

/// Always-visible auth state next to the account name. Invalid is a filled red capsule.
struct AuthBadge: View {
    let health: AuthHealth
    let active: Bool
    var body: some View {
        let tone = health.tone
        HStack(spacing: 4) {
            Image(systemName: health.symbol).font(.system(size: 9, weight: .semibold))
            Text(health.title).font(.system(size: 9.5, weight: .semibold))
        }
        .foregroundStyle(tone == .danger ? Palette.buttonTextOnDanger : tone.ink)
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(tone == .danger ? Palette.danger : tone.wash, in: Capsule())
        .help(health.detail(active: active))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("认证状态：" + health.title)
        .accessibilityValue(health.detail(active: active))
    }
}

/// Explains a state that needs action, with the one button that fixes it.
struct AuthNotice: View {
    @ObservedObject var model: SwitcherModel
    let account: SavedAccount
    let health: AuthHealth
    let active: Bool
    var body: some View {
        if case .locked = health {
            row(tone: .warning, symbol: "lock.fill", text: "登录资料待解锁。后台刷新已跳过，不会反复弹出密码框。",
                button: "解锁登录") { model.unlockLogin(account) }
        } else if case .checking = health {
            HStack(spacing: 8) { ProgressView().controlSize(.small); Text("正在验证新登录…").font(.system(size: 10.5)).foregroundStyle(Palette.muted) }
        } else if case .unavailable = health {
            row(tone: .warning, symbol: "wifi.exclamationmark", text: "本次验证未完成，并不表示登录失效。请检查连接后重试。",
                button: "重新验证") { model.verifySoon(account.id) }
        } else if model.staleLive.contains(account.id) && active {
            row(tone: .warning, symbol: "arrow.triangle.2.circlepath",
                text: "已保存更新的登录，但 Codex 仍在用旧的那份。载入后才会生效。",
                button: "载入新登录…") { model.reloadActive(account) }
        } else if case .invalid = health {
            row(tone: .danger, symbol: "exclamationmark.triangle.fill",
                text: health.detail(active: active) + "。重新登录后会自动替换并重新验证。",
                button: "重新登录") { model.reauthorize(account) }
        } else if case .expired = health, !active {
            row(tone: .warning, symbol: "clock",
                text: health.detail(active: active) + "。",
                button: "重新登录") { model.reauthorize(account) }
        }
    }
    private func row(tone: AuthHealth.Tone, symbol: String, text: String, button: String, action: @escaping () -> Void) -> some View {
        HStack(alignment: .center, spacing: 9) {
            Image(systemName: symbol).font(.system(size: 12, weight: .semibold)).foregroundStyle(tone.ink)
            Text(text).font(.system(size: 10.5)).foregroundStyle(Palette.ink).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button(action: action) { Text(button).font(.system(size: 10.5, weight: .semibold)) }
                .buttonStyle(PressStyle(primary: tone == .danger, danger: tone == .danger))
                .disabled(model.busy || !model.libraryReady)
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(tone.wash, in: RoundedRectangle(cornerRadius: 10))
    }
}

/// Banner above the list so a broken login is noticed without scrolling.
struct AuthSummaryBanner: View {
    @ObservedObject var model: SwitcherModel
    var body: some View {
        let broken = model.invalidAccounts
        if !broken.isEmpty {
            HStack(spacing: 9) {
                Image(systemName: "exclamationmark.octagon.fill").foregroundStyle(Palette.danger)
                Text(broken.count == 1 ? "「\(broken[0].label)」的登录已失效，需要重新登录。" : "\(broken.count) 个账号的登录已失效：" + broken.map(\.label).joined(separator: "、"))
                    .font(.system(size: 11, weight: .medium)).lineLimit(2)
                Spacer(minLength: 8)
                if broken.count == 1 {
                    Button("重新登录") { model.reauthorize(broken[0]) }
                        .buttonStyle(PressStyle(primary: true, danger: true)).font(.system(size: 10.5, weight: .semibold))
                        .disabled(model.busy || !model.libraryReady)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(Palette.dangerWash, in: RoundedRectangle(cornerRadius: 11))
            .overlay(RoundedRectangle(cornerRadius: 11).stroke(Palette.danger.opacity(0.35), lineWidth: 1))
        }
    }
}

struct ExportSheet: View {
    @ObservedObject var model: SwitcherModel
    let request: ExportRequest
    @Environment(\.dismiss) private var dismiss
    @State private var selected: Set<UUID> = []
    @State private var password = ""
    @State private var repeated = ""
    private var problem: String? {
        if selected.isEmpty { return "请至少选择一个账号" }
        if password.count < CredentialTransfer.minimumPassword { return "密码至少 \(CredentialTransfer.minimumPassword) 位" }
        if password != repeated { return "两次输入的密码不一致" }
        return nil
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("导出账号登录").font(.system(size: 20, weight: .semibold))
            Text("生成一个用密码加密的 .stillcodex 文件，可在另一台装有栖言的电脑上导入。")
                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("账号").font(.system(size: 11, weight: .semibold))
                    Spacer()
                    Button(selected.count == model.library.accounts.count ? "全不选" : "全选") {
                        selected = selected.count == model.library.accounts.count ? [] : Set(model.library.accounts.map(\.id))
                    }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Palette.accent)
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(model.library.accounts) { account in
                            Toggle(isOn: Binding(get: { selected.contains(account.id) }, set: { if $0 { selected.insert(account.id) } else { selected.remove(account.id) } })) {
                                HStack(spacing: 6) {
                                    Text(account.label).font(.system(size: 12))
                                    Text(account.email).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
                                    Spacer(minLength: 4)
                                    AuthBadge(health: model.health(account), active: account.identityKey == model.current?.key)
                                }
                            }.toggleStyle(.checkbox)
                        }
                    }.padding(.vertical, 2)
                }.frame(maxHeight: 170)
            }
            VStack(alignment: .leading, spacing: 8) {
                SecureField("设置导出密码（至少 \(CredentialTransfer.minimumPassword) 位）", text: $password).textFieldStyle(.roundedBorder)
                SecureField("再次输入密码", text: $repeated).textFieldStyle(.roundedBorder).onSubmit(run)
            }
            VStack(alignment: .leading, spacing: 6) {
                Label("文件里是这些账号的登录凭据。拿到文件和密码的人可以直接使用账号，请分开发送，用完删除。", systemImage: "lock.doc")
                Label("导出的是同一份登录会话：两台设备同时在用时，先续期的一方会让另一方失效，需要重新登录。长期两边都用，建议在另一台设备单独登录。", systemImage: "arrow.left.arrow.right")
                Label("已失效的登录导出后在对方那里同样无法使用。", systemImage: "xmark.octagon")
            }.font(.system(size: 10.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                if let problem, !password.isEmpty || !repeated.isEmpty { Text(problem).font(.system(size: 10.5)).foregroundStyle(Palette.danger) }
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("导出…", action: run).keyboardShortcut(.defaultAction).disabled(problem != nil)
            }
        }.padding(26).frame(width: 470)
            .onAppear { selected = request.selected }
    }
    private func run() {
        guard problem == nil else { return }
        let ids = selected; let secret = password; let target = model
        dismiss()
        // Let the sheet close before the save panel opens.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(250))
            target.export(ids, password: secret)
        }
    }
}
