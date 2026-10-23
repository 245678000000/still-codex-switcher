import SwiftUI
import AppKit

struct RootView: View {
    @ObservedObject var model: SwitcherModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 218)
            Rectangle().fill(Palette.line).frame(width: 1)
            VStack(spacing: 0) {
                topbar
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        if model.page == "accounts" { accountsPage } else { settingsPage }
                    }.padding(.horizontal, 34).padding(.top, 22).padding(.bottom, 26).frame(maxWidth: 1040)
                        .frame(maxWidth: .infinity)
                }
                if model.busy || !model.message.isEmpty { statusBar }
            }
        }
        .background(Palette.background).foregroundStyle(Palette.ink)
        .frame(minWidth: 880, minHeight: 630)
        .preferredColorScheme(model.appearance)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: model.page)
        .sheet(item: $model.editing) { account in RenameSheet(model: model, account: account) }
        .alert("操作提示", isPresented: Binding(get: { model.errorText != nil }, set: { if !$0 { model.errorText = nil } })) {
            Button("知道了", role: .cancel) { model.errorText = nil }
        } message: { Text(model.errorText ?? "") }
    }
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 11) {
                BrandMark(size: 36)
                VStack(alignment: .leading, spacing: 3) {
                    Text("栖言").font(.system(size: 19, weight: .semibold))
                    Text("CODEX ACCOUNT SWITCHER").font(.system(size: 7.6, weight: .semibold)).tracking(0.9).foregroundStyle(Palette.muted)
                }
            }.padding(.top, 38).padding(.bottom, 35)
            Caption(text: "你的工作，从容接续").padding(.bottom, 14)
            nav("accounts", "square.stack.3d.up", "账号空间", count: model.library.accounts.count)
            nav("settings", "slider.horizontal.3", "偏好与说明")
            Spacer()
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: "key.horizontal").font(.system(size: 21, weight: .light)).foregroundStyle(Palette.accent)
                Text("留在本机，随时就位。 ").font(.system(size: 12, weight: .medium))
                Text("凭据存入 macOS 钥匙串。\n不保存账号密码，不上传登录资料。")
                    .font(.system(size: 10.5)).foregroundStyle(Palette.muted).lineSpacing(5)
            }.padding(15).frame(maxWidth: .infinity, alignment: .leading)
                .background(Palette.surface.opacity(0.65), in: RoundedRectangle(cornerRadius: 14)).padding(.bottom, 18)
            HStack(spacing: 6) {
                Circle().fill(Palette.accent).frame(width: 5, height: 5)
                Text(model.demo ? "演示模式 · 虚构账号" : "本地账号管理").font(.system(size: 10))
                Spacer(); Text("1.0").font(.system(size: 10, design: .monospaced))
            }.foregroundStyle(Palette.muted).padding(.bottom, 22)
        }.padding(.horizontal, 19).background(Palette.sidebar)
    }
    private func nav(_ page: String, _ symbol: String, _ title: String, count: Int? = nil) -> some View {
        Button { model.page = page } label: {
            HStack(spacing: 10) {
                Image(systemName: symbol).font(.system(size: 14)).frame(width: 18)
                Text(title).font(.system(size: 12, weight: model.page == page ? .semibold : .regular))
                Spacer()
                if let count { Text("\(count)").font(.system(size: 10, weight: .medium)).foregroundStyle(Palette.muted) }
            }.foregroundStyle(model.page == page ? Palette.accent : Palette.muted)
                .padding(.horizontal, 12).padding(.vertical, 12)
                .background(model.page == page ? Palette.accentWash : .clear, in: RoundedRectangle(cornerRadius: 10))
        }.buttonStyle(.plain).padding(.bottom, 5)
    }
    private var topbar: some View {
        HStack(spacing: 9) {
            Text("工作台").foregroundStyle(Palette.muted)
            Text("/").foregroundStyle(Palette.line)
            Text(model.page == "accounts" ? "账号空间" : "偏好与说明")
            Spacer()
            if model.demo { Text("演示数据").font(.system(size: 10, weight: .medium)).foregroundStyle(Palette.accent).padding(.horizontal, 9).padding(.vertical, 5).background(Palette.accentWash, in: Capsule()) }
            Button { model.openCodex() } label: { HStack(spacing: 5) { Text("打开 Codex"); Image(systemName: "arrow.up.right").font(.system(size: 9)) } }
                .buttonStyle(.plain).foregroundStyle(Palette.muted).disabled(model.busy)
        }.font(.system(size: 11)).padding(.horizontal, 34).padding(.top, 23).padding(.bottom, 16)
    }
    private var accountsPage: some View {
        Group {
            VStack(alignment: .leading, spacing: 10) {
                Caption(text: "ONE CLICK. ANOTHER PERSPECTIVE.")
                Text("账号就位，一键接续。").font(.system(size: 28, weight: .semibold)).tracking(-0.8)
                Text("保存你的 Codex 登录状态。换个账号，不必重新来过。")
                    .font(.system(size: 12)).foregroundStyle(Palette.muted)
            }
            currentCard
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    Text("已保存账号").font(.system(size: 14, weight: .semibold))
                    Text(String(format: "%02d", model.library.accounts.count)).font(.system(size: 11, design: .monospaced)).foregroundStyle(Palette.muted)
                    Spacer()
                    if model.library.accounts.count > 3 {
                        HStack(spacing: 5) { Image(systemName: "magnifyingglass"); TextField("查找账号", text: $model.query).textFieldStyle(.plain) }
                            .font(.system(size: 11)).foregroundStyle(Palette.muted).frame(width: 140).padding(8).background(Palette.surface, in: RoundedRectangle(cornerRadius: 7))
                    }
                    Button { model.addAccount() } label: { Label("添加账号", systemImage: "plus").font(.system(size: 11, weight: .medium)) }
                        .buttonStyle(PressStyle()).disabled(model.busy || !model.libraryReady).keyboardShortcut("n", modifiers: .command)
                }
                if model.library.accounts.isEmpty { emptyState }
                else {
                    VStack(spacing: 10) {
                        ForEach(model.accounts) { account in AccountRow(model: model, account: account) }
                    }
                    if model.accounts.isEmpty { Text("没有匹配的账号").font(.system(size: 12)).foregroundStyle(Palette.muted).padding(20) }
                }
            }
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: "info.circle").padding(.top, 1)
                Text("切换会重新打开 Codex。请先保存正在进行的任务，结束其他 Codex 命令行会话。")
                    .lineSpacing(4).fixedSize(horizontal: false, vertical: true)
            }.font(.system(size: 10.5)).foregroundStyle(Palette.muted)
        }
    }
    private var currentCard: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 6) {
                Circle().fill(model.current == nil ? Palette.muted : Palette.accent).frame(width: 5, height: 5)
                Caption(text: "当前本机配置")
                Spacer()
                Text(model.demo ? "CODEX DESKTOP" : "CODEX " + (model.desktop?.version ?? "未检测到"))
                    .font(.system(size: 9, weight: .medium, design: .monospaced)).foregroundStyle(Palette.muted)
            }
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14).fill(Palette.accentWash).frame(width: 52, height: 52)
                    Image(systemName: "terminal").font(.system(size: 25, weight: .light)).foregroundStyle(Palette.accent)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text(model.active?.label ?? (model.current == nil ? "先让一个账号就位" : "当前 Codex 账号"))
                        .font(.system(size: 18, weight: .medium)).lineLimit(1)
                    Text(model.current?.email ?? "在 Codex 登录后保存，或通过下方添加账号。")
                        .font(.system(size: 11)).foregroundStyle(Palette.muted).lineLimit(1)
                }
                Spacer(minLength: 8)
                Button { model.saveCurrent() } label: {
                    Label(model.active == nil ? "保存当前账号" : "更新登录备份", systemImage: "tray.and.arrow.down")
                        .font(.system(size: 11, weight: .medium))
                }.buttonStyle(PressStyle(primary: true)).disabled(model.busy || !model.libraryReady)
                    .keyboardShortcut("s", modifiers: .command)
            }
            Hairline()
            HStack(spacing: 6) {
                Image(systemName: "checkmark.shield").foregroundStyle(Palette.accent)
                Text("独立保存 · 切换前备份 · 支持回滚")
                Spacer()
                IconButton(symbol: "arrow.clockwise", label: "刷新本机登录状态") { model.refresh() }.disabled(model.busy)
            }.font(.system(size: 10)).foregroundStyle(Palette.muted)
        }.padding(22).background(Palette.surface, in: RoundedRectangle(cornerRadius: 17))
            .overlay(RoundedRectangle(cornerRadius: 17).stroke(Palette.line, lineWidth: 1))
    }
    private var emptyState: some View {
        HStack(alignment: .center, spacing: 20) {
            ZStack {
                RoundedRectangle(cornerRadius: 15).stroke(Palette.line, lineWidth: 1).frame(width: 64, height: 74).rotationEffect(.degrees(-8)).offset(x: -5)
                RoundedRectangle(cornerRadius: 15).fill(Palette.surface).frame(width: 64, height: 74)
                    .overlay(RoundedRectangle(cornerRadius: 15).stroke(Palette.line, lineWidth: 1))
                Image(systemName: "person.crop.square").font(.system(size: 26, weight: .ultraLight)).foregroundStyle(Palette.accent)
            }.padding(.leading, 4)
            VStack(alignment: .leading, spacing: 8) {
                Text("从你正在使用的账号开始").font(.system(size: 14, weight: .medium))
                Text("点击上方「保存当前账号」，再添加其他账号。\n每个账号首次登录一次，之后点选切换。")
                    .font(.system(size: 11)).foregroundStyle(Palette.muted).lineSpacing(5)
            }
            Spacer(minLength: 0)
        }.padding(25).frame(maxWidth: .infinity, minHeight: 146)
            .background(Palette.sidebar.opacity(0.45), in: RoundedRectangle(cornerRadius: 14))
    }
    private var statusBar: some View {
        HStack(spacing: 9) {
            if model.busy { ProgressView().controlSize(.small) }
            else { Image(systemName: model.demo ? "eye" : "checkmark.circle").foregroundStyle(Palette.accent) }
            Text(model.busy ? model.phase : model.message).font(.system(size: 11)).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 6)
            if model.loginWaiting { Button("取消登录") { model.cancelLogin() }.buttonStyle(.plain).foregroundStyle(Palette.accent) }
            else if !model.busy { IconButton(symbol: "xmark", label: "关闭提示") { model.message = "" } }
        }.foregroundStyle(Palette.muted).padding(.horizontal, 25).padding(.vertical, 10)
            .frame(maxWidth: .infinity, minHeight: 50).background(Palette.sidebar)
    }
    private var settingsPage: some View {
        Group {
            VStack(alignment: .leading, spacing: 10) {
                Caption(text: "MAKE YOURSELF AT HOME.")
                Text("舒服一点，简单一点。").font(.system(size: 28, weight: .semibold)).tracking(-0.8)
                Text("这是 Codex 的账号管理工具，不是另一个聊天客户端。 ").font(.system(size: 12)).foregroundStyle(Palette.muted)
            }
            settingsBlock("外观", symbol: "circle.lefthalf.filled") {
                Picker("显示模式", selection: Binding(get: { model.library.appearance }, set: { model.setAppearance($0) })) {
                    Text("跟随系统").tag("system"); Text("浅色").tag("light"); Text("深色").tag("dark")
                }.pickerStyle(.segmented).labelsHidden().frame(width: 270).disabled(model.busy)
            }
            settingsBlock("登录资料只留在本机", symbol: "lock.shield") {
                VStack(alignment: .leading, spacing: 11) {
                    note("保存什么", "保留官方登录生成的会话凭据；密码始终在官方登录页面输入。")
                    note("放在哪里", "保存的凭据和回滚备份进入 macOS 钥匙串；账号备注与邮箱保存在本机列表。Codex 使用中的 auth.json 仍由 Codex 管理。")
                    note("怎么切换", "退出 Codex → 保存最新凭据 → 原子替换登录文件 → 重新打开 Codex。聊天记录、配置与项目保持原样。")
                    note("使用边界", "适配 ChatGPT 登录与 file 存储模式。登录状态过期或被撤销时，需要重新登录。订阅标签来自缓存，不代表实时额度。")
                }
            }
            settingsBlock("恢复与兼容性", symbol: "arrow.uturn.backward") {
                VStack(alignment: .leading, spacing: 13) {
                    Text("首次切换请在 Codex 头像里核对账号。切换与订阅归属以 Codex 实际显示为准；本工具为独立第三方应用。")
                        .font(.system(size: 11)).foregroundStyle(Palette.muted).lineSpacing(5)
                    HStack {
                        Button("恢复上次切换前的账号") { model.restore() }.buttonStyle(PressStyle()).disabled(model.busy)
                        Spacer()
                        Text("Apple Silicon · macOS 14+").font(.system(size: 10, design: .monospaced)).foregroundStyle(Palette.muted)
                    }
                }
            }
            Text("当前数据目录：" + (model.demo ? "演示数据 · 不读写真实账号" : model.paths.root.path))
                .font(.system(size: 10, design: .monospaced)).foregroundStyle(Palette.muted).textSelection(.enabled)
        }
    }
    private func settingsBlock<Content: View>(_ title: String, symbol: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 17) {
            Label(title, systemImage: symbol).font(.system(size: 13, weight: .semibold))
            content()
        }.padding(21).frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.surface, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Palette.line, lineWidth: 1))
    }
    private func note(_ title: String, _ body: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Text(title).foregroundStyle(Palette.ink).frame(width: 53, alignment: .leading)
            Text(body).foregroundStyle(Palette.muted).lineSpacing(4).fixedSize(horizontal: false, vertical: true)
        }.font(.system(size: 11))
    }
}

struct AccountRow: View {
    @ObservedObject var model: SwitcherModel
    let account: SavedAccount
    @State private var hover = false
    var isCurrent: Bool { account.identityKey == model.current?.key }
    var body: some View {
        HStack(spacing: 13) {
            AccountAvatar(account: account)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 7) {
                    Text(account.label).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    Text(account.plan.uppercased()).font(.system(size: 8.5, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Palette.muted).padding(.horizontal, 6).padding(.vertical, 3).background(Palette.sidebar, in: RoundedRectangle(cornerRadius: 4))
                }
                Text(account.email).font(.system(size: 10.5)).foregroundStyle(Palette.muted).lineLimit(1)
            }
            Spacer(minLength: 10)
            if isCurrent {
                Label("当前配置", systemImage: "checkmark.circle.fill").font(.system(size: 10.5)).foregroundStyle(Palette.accent).padding(.trailing, 6)
            } else {
                Button { model.confirmSwitch(account) } label: {
                    HStack(spacing: 7) { Text("切换并重启"); Image(systemName: "arrow.right").font(.system(size: 9)) }.font(.system(size: 10.5, weight: .medium))
                }.buttonStyle(PressStyle()).disabled(model.busy)
            }
            Menu {
                Button("修改账号备注") { model.editing = account }
                Button("移除保存记录…") { model.remove(account) }
            } label: { Image(systemName: "ellipsis").frame(width: 18, height: 24).foregroundStyle(Palette.muted) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().disabled(model.busy).help("账号操作")
        }.padding(.horizontal, 16).padding(.vertical, 14)
            .background(hover ? Palette.surface : Palette.surface.opacity(0.72), in: RoundedRectangle(cornerRadius: 13))
            .overlay(RoundedRectangle(cornerRadius: 13).stroke(isCurrent ? Palette.accent.opacity(0.28) : Palette.line, lineWidth: 1))
            .onHover { hover = $0 }
    }
}
struct RenameSheet: View {
    @ObservedObject var model: SwitcherModel
    let account: SavedAccount
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("给账号一个熟悉的名字").font(.system(size: 20, weight: .semibold))
            Text("仅修改本地备注，不影响 Codex 里的账号信息。").font(.system(size: 12)).foregroundStyle(.secondary)
            TextField("例如：工作账号", text: $name).textFieldStyle(.roundedBorder).onSubmit(save)
            HStack { Spacer(); Button("取消") { dismiss() }.keyboardShortcut(.cancelAction); Button("保存", action: save).keyboardShortcut(.defaultAction).disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
        }.padding(28).frame(width: 390).onAppear { name = account.label }
    }
    private func save() { model.rename(account, label: name); dismiss() }
}
