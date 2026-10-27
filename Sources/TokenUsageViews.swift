import AppKit
import SwiftUI
import Charts
import UniformTypeIdentifiers

@MainActor final class TokenUsageController: ObservableObject {
    @Published var snapshot: TokenSnapshot?
    @Published var loading = false
    @Published var notice = ""
    @Published var period: TokenPeriod = .week
    private let scanner = TokenLogScanner()
    private var task: Task<Void, Never>?
    func refresh(home: URL) {
        guard !loading else { return }
        loading = true; notice = ""
        task = Task {
            defer { loading = false; task = nil }
            do { snapshot = try await scanner.scan(home: home) }
            catch is CancellationError { notice = "读取已停止，原有统计仍保留。" }
            catch { notice = "本地日志读取未完成，请检查目录权限后重试。" }
        }
    }
    func cancel() { task?.cancel() }
    func export() {
        guard let snapshot else { return }
        let panel = NSSavePanel(); panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "Codex-Token-\(period.rawValue).csv"
        panel.title = "导出本机桌面端每日 Token 统计"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try TokenCSV.make(snapshot.summarize(period)).write(to: url, atomically: true, encoding: .utf8)
            notice = "CSV 已导出，仅包含日期和计数。"
        } catch { notice = "导出未完成，请检查所选目录的写入权限。" }
    }
    func seedDemo(now: Date = Date()) {
        var s = TokenSession(id: "synthetic-desktop", eligible: true)
        for day in 0..<30 {
            let date = Calendar.current.date(byAdding: .day, value: -day, to: now)!
            let input = Int64((day % 5 + 2) * 418_500)
            s.events.append(TokenEvent(date: date, model: day % 3 == 0 ? "gpt-demo-small" : "gpt-demo", tokens: TokenAmounts(input: input, cached: input / 2, output: 28_400 + Int64(day * 1_530), reasoning: 12_200)))
        }
        snapshot = TokenSnapshot(sessions: [s], scannedFiles: 1, fetchedAt: now)
    }
}

struct TokenUsagePage: View {
    @ObservedObject var controller: TokenUsageController
    let home: URL
    let demo: Bool
    private var summary: TokenSummary { (controller.snapshot ?? TokenSnapshot()).summarize(controller.period) }
    private func number(_ value: Int64) -> String { value.formatted(.number.locale(Locale(identifier: "en_US"))) }
    private func compact(_ value: Int64) -> String {
        if value >= 1_000_000 { return String(format: "%.2fM", Double(value) / 1_000_000) }
        if value >= 10_000 { return String(format: "%.1fK", Double(value) / 1_000) }
        return number(value)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 10) {
                Caption(text: "A CLEARER VIEW OF YOUR USAGE.")
                Text("Token 消费统计").font(.system(size: 28, weight: .semibold)).tracking(-0.8)
                Text("看清每次投入。仅统计本机 Codex 桌面端主会话。")
                    .font(.system(size: 12)).foregroundStyle(Palette.muted)
            }
            HStack(spacing: 10) {
                Picker("统计区间", selection: $controller.period) {
                    ForEach(TokenPeriod.allCases) { period in Text(period.rawValue).tag(period) }
                }.pickerStyle(.segmented).labelsHidden().frame(maxWidth: 330)
                Spacer(minLength: 4)
                Button { controller.export() } label: { Label("导出", systemImage: "square.and.arrow.up") }
                    .buttonStyle(PressStyle()).disabled(controller.snapshot == nil || controller.loading)
                Button { if demo { controller.seedDemo() } else { controller.refresh(home: home) } } label: {
                    Label(controller.loading ? "读取中" : "刷新", systemImage: "arrow.clockwise")
                }.buttonStyle(PressStyle()).disabled(controller.loading)
            }.font(.system(size: 11))
            if controller.snapshot == nil {
                VStack(spacing: 14) {
                    if controller.loading { ProgressView(); Text("正在本机整理 Token 计数…") }
                    else { Image(systemName: "chart.bar.xaxis").font(.system(size: 30)); Text("尚未载入统计") }
                    Text("只读日志 · 无网络请求 · 保留原始会话")
                        .font(.system(size: 11)).foregroundStyle(Palette.muted)
                }.frame(maxWidth: .infinity, minHeight: 230).tokenCard()
            } else {
                totals
                trend
                models
            }
            methodology
            HStack(spacing: 6) {
                if controller.loading { ProgressView().controlSize(.mini) }
                else { Image(systemName: "internaldrive").foregroundStyle(Palette.accent) }
                Text(status).font(.system(size: 10)).foregroundStyle(Palette.muted)
                Spacer()
            }
            if !controller.notice.isEmpty { Text(controller.notice).font(.system(size: 11)).foregroundStyle(Palette.accent) }
        }.onAppear {
            if demo { if controller.snapshot == nil { controller.seedDemo() } }
            else { controller.refresh(home: home) }
        }
    }
    private var status: String {
        guard let s = controller.snapshot else { return "首次读取在后台进行，界面保持可操作。" }
        return "\(s.fetchedAt.formatted(date: .omitted, time: .shortened)) 更新 · 已扫描 \(s.scannedFiles) 份日志 · 本页打开时每分钟刷新"
    }
    private var totals: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 8) {
                    Caption(text: "所选区间 · TOTAL TOKENS")
                    Text(compact(summary.total.total)).font(.system(size: 43, weight: .medium, design: .rounded)).monospacedDigit().foregroundStyle(Palette.accent)
                        .help(number(summary.total.total) + " Tokens")
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 7) {
                    Text(number(summary.total.total) + " Tokens").font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                    Text("\(summary.sessions) 个有用量的主会话").font(.system(size: 11)).foregroundStyle(Palette.muted)
                }
            }
            Hairline()
            HStack(alignment: .top, spacing: 12) {
                metric("输入", summary.total.input, note: "含缓存输入")
                metric("缓存输入", summary.total.cached, note: "输入的子集")
                metric("输出", summary.total.output, note: "含推理输出")
                metric("推理", summary.total.reasoning, note: "输出的子集")
            }
        }.tokenCard()
    }
    private func metric(_ title: String, _ amount: Int64, note: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.system(size: 11)).foregroundStyle(Palette.muted)
            Text(compact(amount)).font(.system(size: 19, weight: .medium, design: .rounded)).monospacedDigit().help(number(amount))
            Text(note).font(.system(size: 9)).foregroundStyle(Palette.muted)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private var trend: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("每日趋势", systemImage: "chart.bar.xaxis").font(.system(size: 13, weight: .semibold))
                Spacer()
                Text("输入 + 输出 · 本地时区").font(.system(size: 10)).foregroundStyle(Palette.muted)
            }
            if summary.total.total == 0 {
                Text("此区间暂无可用的桌面端 Token 记录。\n其他设备、插件、CLI 与派生会话不在此统计范围。")
                    .font(.system(size: 12)).foregroundStyle(Palette.muted).lineSpacing(6)
                    .frame(maxWidth: .infinity, minHeight: 140)
            } else {
                Chart(summary.days) { day in
                    BarMark(x: .value("日期", day.date, unit: .day), y: .value("Token", day.tokens.total))
                        .foregroundStyle(Palette.accent.gradient).cornerRadius(3)
                        .accessibilityLabel(day.date.formatted(date: .abbreviated, time: .omitted))
                        .accessibilityValue(number(day.tokens.total) + " Tokens")
                }.chartXAxis { AxisMarks(values: .automatic(desiredCount: 6)) { _ in AxisValueLabel(format: .dateTime.month(.twoDigits).day(.twoDigits)); AxisTick() } }
                    .chartYAxis {
                        AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                            AxisGridLine()
                            AxisValueLabel { if let amount = value.as(Int64.self) { Text(compact(amount)) } }
                        }
                    }
                    .frame(height: 170)
            }
        }.tokenCard()
    }
    private var models: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("模型分布", systemImage: "square.stack.3d.up").font(.system(size: 13, weight: .semibold))
                Spacer(); Text("按本地记录的模型名称").font(.system(size: 10)).foregroundStyle(Palette.muted)
            }
            if summary.models.isEmpty { Text("有用量后，这里会展示模型明细。").font(.system(size: 11)).foregroundStyle(Palette.muted) }
            ForEach(summary.models) { row in
                VStack(spacing: 7) {
                    HStack {
                        Text(row.id).font(.system(size: 11, design: .monospaced)).lineLimit(1)
                        Spacer()
                        Text(number(row.tokens.total)).font(.system(size: 11, design: .rounded)).monospacedDigit()
                        Text(String(format: "%.1f%%", Double(row.tokens.total) / Double(max(1, summary.total.total)) * 100))
                            .font(.system(size: 10)).foregroundStyle(Palette.muted).frame(width: 46, alignment: .trailing)
                    }
                    GeometryReader { g in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Palette.accentWash)
                            Capsule().fill(Palette.accent.opacity(0.8)).frame(width: g.size.width * Double(row.tokens.total) / Double(max(1, summary.total.total)))
                        }
                    }.frame(height: 4)
                }.padding(.vertical, 3)
            }
        }.tokenCard()
    }
    private var methodology: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("本机统计，不是订阅账单", systemImage: "info.circle").font(.system(size: 12, weight: .medium))
            Text("总量 = 输入 + 输出；缓存、推理已包含在其中，不重复相加。按累计计数增量去重，保留已归档主会话。日志未记录的可选类别按 0 展示。Token 数不等于 5 小时 / 7 天额度，也不换算订阅费用。")
            Text("历史会话可能跨账号继续使用，暂不按账号分摊。仅包含来源明确的 Codex 桌面端主会话；CLI、VS Code 插件、分叉与子代理会话、临时预热及缺失日志未计入。")
            if let s = controller.snapshot {
                Text("已排除 \(s.excludedFiles) 份非主会话日志。" + (s.warnings > 0 ? "另有 \(s.warnings) 处读取或计数异常已跳过，当前结果可能不完整。" : ""))
                    .foregroundStyle(s.warnings > 0 ? Palette.adaptive(0xA57626, 0xE1B875) : Palette.muted)
            }
            Text("数据目录：" + (demo ? "虚构演示数据" : home.path)).font(.system(size: 9, design: .monospaced)).textSelection(.enabled)
        }.font(.system(size: 10.5)).foregroundStyle(Palette.muted).lineSpacing(4)
            .padding(17).frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.sidebar.opacity(0.6), in: RoundedRectangle(cornerRadius: 12))
    }
}
private extension View {
    func tokenCard() -> some View {
        padding(21).frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.surface, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Palette.line, lineWidth: 1))
    }
}
