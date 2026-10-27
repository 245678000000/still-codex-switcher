import SwiftUI

struct DiagnosticsPage: View {
    @ObservedObject var model: SwitcherModel
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 10) {
                Caption(text: "OBSERVE. DON'T GUESS.")
                Text("状态有据，不靠猜测。").font(.system(size: 28, weight: .semibold))
                Text("逐项检查账号连接与额度。不切换账号，不发送聊天消息。").font(.system(size: 12)).foregroundStyle(Palette.muted)
            }
            VStack(alignment: .leading, spacing: 8) {
                Label("基础诊断 · 手动运行", systemImage: "stethoscope").font(.system(size: 13, weight: .semibold))
                Text(DiagnosticReport.boundary).font(.system(size: 11)).foregroundStyle(Palette.muted).lineSpacing(4)
            }.padding(18).frame(maxWidth: .infinity, alignment: .leading).background(Palette.accentWash, in: RoundedRectangle(cornerRadius: 14))
            if model.library.accounts.isEmpty {
                Text("先在账号空间保存或添加一个账号，再进行检查。").font(.system(size: 13)).foregroundStyle(Palette.muted).padding(.vertical, 25)
            }
            ForEach(model.library.accounts) { account in
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 12) {
                        AccountAvatar(account: account, size: 38)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(account.label).font(.system(size: 14, weight: .semibold))
                            Text(account.email).font(.system(size: 10)).foregroundStyle(Palette.muted).lineLimit(1)
                        }
                        Spacer()
                        if model.diagnosingAccountID == account.id {
                            ProgressView().controlSize(.small)
                            Button("取消检查") { model.cancelDiagnostics() }.buttonStyle(PressStyle())
                        } else {
                            Button("基础检查…") { model.diagnose(account) }.buttonStyle(PressStyle()).disabled(model.busy || model.refreshingQuotas || !model.libraryReady)
                        }
                    }
                    if model.diagnosingAccountID == account.id { Text("正在检查 · 如有旧结果，以下为上次记录").font(.system(size: 11)).foregroundStyle(Palette.muted) }
                    if let report = model.diagnostics[account.id] {
                        Hairline()
                        HStack {
                            Text(report.summary).font(.system(size: 12, weight: .medium))
                            Spacer()
                            Text((report.isStale() ? "上次结果 · " : "本次检查 · ") + report.checkedAt.formatted(date: .omitted, time: .standard)).font(.system(size: 10)).foregroundStyle(Palette.muted)
                        }
                        ForEach(report.checks) { item in
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: item.level == .passed ? "checkmark.circle" : item.level == .attention ? "exclamationmark.circle" : "questionmark.circle")
                                    .foregroundStyle(item.level == .attention ? Palette.avatar(2) : item.level == .passed ? Palette.accent : Palette.muted)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(item.title).font(.system(size: 11, weight: .medium))
                                    Text(item.detail).font(.system(size: 10.5)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                        if !report.models.isEmpty {
                            DisclosureGroup("查看模型标识（\(report.models.count)）") {
                                Text(report.models.joined(separator: " · ")).font(.system(size: 10, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 6)
                            }.font(.system(size: 10.5)).foregroundStyle(Palette.muted)
                        }
                    } else { Text("尚未检查 · 点击后先确认，再连接官方服务").font(.system(size: 11)).foregroundStyle(Palette.muted) }
                }.padding(20).background(Palette.surface, in: RoundedRectangle(cornerRadius: 16)).overlay(RoundedRectangle(cornerRadius: 16).stroke(Palette.line, lineWidth: 1))
            }
            VStack(alignment: .leading, spacing: 9) {
                Text("模型指纹 · 实验性 · 尚未接入").font(.system(size: 12, weight: .semibold))
                Text("基础诊断不含指纹评分。参考库验证完成后再单独提供手动测试；届时会先说明请求数量与额度消耗。指纹相似度不是官方风控状态，也不证明当前聊天的模型身份。").font(.system(size: 11)).foregroundStyle(Palette.muted).lineSpacing(4)
            }.padding(18).frame(maxWidth: .infinity, alignment: .leading).background(Palette.surface, in: RoundedRectangle(cornerRadius: 14))
        }
    }
}
