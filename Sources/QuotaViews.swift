import SwiftUI

struct AccountQuotaView: View {
    let state: QuotaState
    let disabled: Bool
    let refresh: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .top, spacing: 24) {
                QuotaMeter(title: "5 小时剩余", window: state.snapshot?.fiveHours)
                QuotaMeter(title: "7 天剩余", window: state.snapshot?.sevenDays)
            }.opacity(state.isStale() ? 0.55 : 1)
            HStack(spacing: 8) {
                if state.loading { ProgressView().controlSize(.mini) }
                Text(state.status()).font(.system(size: 9.5)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button("刷新", action: refresh).font(.system(size: 10)).foregroundStyle(Palette.accent).buttonStyle(.plain).disabled(disabled)
            }
        }
    }
}
private struct QuotaMeter: View {
    let title: String
    let window: QuotaWindow?
    var tint: Color {
        guard let window else { return Palette.muted }
        if window.remaining <= 10 { return Palette.adaptive(0xB94343, 0xED9290) }
        if window.remaining <= 25 { return Palette.adaptive(0xA57626, 0xE1B875) }
        return Palette.accent
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.system(size: 10)).foregroundStyle(Palette.muted)
                Spacer()
                Text(window?.percent ?? "—").font(.system(size: 11, weight: .medium, design: .rounded)).monospacedDigit().foregroundStyle(tint)
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Palette.accentWash)
                    Capsule().fill(tint).frame(width: proxy.size.width * CGFloat(window?.remaining ?? 0) / 100)
                }
            }.frame(height: 5)
            Text(window?.resetLabel() ?? "暂未提供数据").font(.system(size: 9)).foregroundStyle(Palette.muted).lineLimit(2).fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue((window?.percent ?? "暂无数据") + "，" + (window?.resetLabel() ?? "待刷新"))
    }
}
