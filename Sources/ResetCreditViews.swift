import SwiftUI

struct ResetCreditRow: View {
    @ObservedObject var model: SwitcherModel
    let account: SavedAccount
    @State private var showDetails = false
    private var state: QuotaState { model.quotas[account.id] ?? QuotaState() }
    private var cards: ResetCredits? { state.snapshot?.resetCredits }
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .center, spacing: 8) {
                Button { showDetails.toggle() } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "ticket").font(.system(size: 10))
                        Text(cards?.countLabel ?? "重置卡 —").fontWeight(.medium)
                    }
                }.buttonStyle(.plain).foregroundStyle(Palette.accent)
                .popover(isPresented: $showDetails) {
                    Text(cards?.details() ?? "点击刷新后查看重置卡数量与有效期。")
                        .font(.system(size: 11)).lineSpacing(5).padding(16).frame(maxWidth: 330, alignment: .leading)
                }
                Text(cards?.expiryLabel() ?? (state.snapshot == nil ? "待刷新" : "组件未返回")).foregroundStyle(Palette.muted).lineLimit(2)
                Spacer(minLength: 2)
                Button(model.resettingAccountID == account.id ? "处理中…" : account.resetAttempt != nil ? "核对上次请求…" : "使用一张…") { model.useReset(account) }
                    .buttonStyle(.plain).foregroundStyle(Palette.accent)
                    .disabled(model.busy || model.refreshingQuotas || !model.libraryReady || (account.resetAttempt == nil && !state.canStartReset()))
                    .help("确认后使用 1 张已有重置卡，不购买付费重置")
            }.font(.system(size: 9.5))
            if let note = model.resetNotices[account.id] ?? (account.resetAttempt != nil ? "上次结果待确认 · 核对时沿用同一请求，避免重复扣卡" : state.isStale() ? "上次卡片信息 · 刷新后再使用" : nil) {
                Text(note).font(.system(size: 9)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
            }
        }.padding(.top, 2)
    }
}

@MainActor extension SwitcherModel {
    func seedResetCards(pending: Bool = false) {
        guard demo, library.accounts.count >= 2 else { return }
        let now = Date()
        quotas[library.accounts[0].id]?.snapshot?.resetCredits = ResetCredits(availableCount: 2, credits: [
            ResetCredit(id: "demo-card-a", resetType: "codexRateLimits", status: "available", expiresAt: now.addingTimeInterval(86400 * 5), expiryKnown: true),
            ResetCredit(id: "demo-card-b", resetType: "codexRateLimits", status: "available", expiresAt: now.addingTimeInterval(86400 * 7), expiryKnown: true)])
        quotas[library.accounts[1].id]?.snapshot?.resetCredits = ResetCredits(availableCount: 0, credits: [])
        if pending { library.accounts[0].resetAttempt = ResetAttempt(idempotencyKey: UUID().uuidString, creditID: "demo-card-a", createdAt: now) }
    }
}
