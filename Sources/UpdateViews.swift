import SwiftUI

struct UpdateIndicator: View {
    @ObservedObject var updater: UpdateController
    let action: () -> Void
    var body: some View {
        if updater.available != nil {
            Button(action: action) {
                Label("有新版本", systemImage: "arrow.down.circle")
                    .font(.system(size: 10, weight: .medium)).foregroundStyle(Palette.accent)
                    .padding(.horizontal, 9).padding(.vertical, 5).background(Palette.accentWash, in: Capsule())
            }.buttonStyle(.plain).help("查看新版说明与下载入口")
        }
    }
}

struct UpdatePanel: View {
    @ObservedObject var updater: UpdateController
    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                Text("当前版本 " + AppRelease.current).font(.system(size: 11, design: .monospaced)).foregroundStyle(Palette.muted)
                Spacer()
                if updater.checking { ProgressView().controlSize(.small) }
                Button("检查更新") { updater.check() }.buttonStyle(PressStyle()).disabled(updater.checking)
            }
            Toggle("自动检查更新", isOn: Binding(get: { updater.automaticallyChecks }, set: updater.setAutomatic))
                .toggleStyle(.switch).controlSize(.small).font(.system(size: 12))
            Toggle("接收预览版本", isOn: Binding(get: { updater.includesPreviews }, set: updater.setPreviews))
                .toggleStyle(.switch).controlSize(.small).font(.system(size: 12))
            Text("启动时检查，之后每 12 小时检查一次；仅检查本仓库的 Mac 安装包。发现新版时提示，由你决定下载和替换，不会自动退出或安装。")
                .font(.system(size: 10.5)).foregroundStyle(Palette.muted).lineSpacing(4).fixedSize(horizontal: false, vertical: true)
            Hairline()
            Text(updater.status).font(.system(size: 11)).foregroundStyle(updater.available == nil ? Palette.muted : Palette.accent)
                .fixedSize(horizontal: false, vertical: true)
            if let checked = updater.lastChecked {
                Text("上次成功检查：" + checked.formatted(date: .abbreviated, time: .shortened)).font(.system(size: 10)).foregroundStyle(Palette.muted)
            }
            if let release = updater.available {
                ScrollView {
                    Text(verbatim: release.notes.isEmpty ? "请在发布页查看版本说明。" : release.notes)
                        .font(.system(size: 11)).lineSpacing(4).foregroundStyle(Palette.muted)
                        .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                }.frame(maxHeight: 130)
                Button("查看新版 / 下载…") { updater.openRelease() }.buttonStyle(PressStyle(primary: true))
            } else {
                Button("打开 GitHub 发布页") { updater.openRelease() }.font(.system(size: 10.5)).buttonStyle(.plain).foregroundStyle(Palette.accent)
            }
            Text("只向 GitHub 请求公开版本列表，不发送账号、邮箱或登录凭据。")
                .font(.system(size: 10)).foregroundStyle(Palette.muted)
        }
    }
}
