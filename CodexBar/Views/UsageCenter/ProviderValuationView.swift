import SwiftUI

struct ProviderValuationView: View {
    let provider: String
    let title: String
    let subtitle: String
    let pricingURL: URL
    let periods: [GeminiValuationPeriod]
    let priceBook: GeminiPriceBook
    let hasOfflineNodes: Bool
    let isRefreshing: Bool
    let onRefresh: () -> Void
    @State private var visibleCount = 8

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            headerBar
            Text(subtitle).font(.caption2).foregroundStyle(.secondary)
            if hasOfflineNodes {
                Text("部分开启该渠道的远程节点离线, 待节点上线补传后自动对齐周限估值")
                    .font(.caption2).foregroundStyle(.orange)
            }
            if periods.isEmpty {
                Text(isRefreshing ? "正在计算周期估值…" : "等待包含 7d 重置时间的额度记录与模型样本")
                    .font(.caption).foregroundStyle(.secondary).padding(.vertical, 8)
            }
            ForEach(periods.prefix(visibleCount)) { period in
                ProviderPeriodCard(period: period, estimateText: projectedText(for: period)) {
                    ProviderPeriodDetails(period: period, provider: provider, priceBook: priceBook)
                }
            }
            if periods.count > visibleCount {
                Button("更多周期") { visibleCount += 8 }.buttonStyle(.plain).font(.caption)
            }
            Text("按标准 API 单价 (含促销期与长上下文阶梯) 及已记录 7d 额度消耗占比外推周限总额")
                .font(.caption2).foregroundStyle(.secondary)
            Text("价格快照 \(priceBook.asOf)")
                .font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(14)
        .usageCenterCard()
    }

    private var headerBar: some View {
        HStack {
            Text(title).font(.caption.weight(.semibold))
            Spacer()
            if isRefreshing {
                ProgressView().controlSize(.mini)
            }
            Menu {
                Link("官方 API 单价", destination: pricingURL)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuIndicator(.hidden).menuStyle(.borderlessButton).frame(width: 24)
            Button(action: onRefresh) {
                Image(systemName: "arrow.clockwise.circle")
            }
            .buttonStyle(.plain).disabled(isRefreshing).help("刷新价值统计")
        }
    }

    private func projectedText(for period: GeminiValuationPeriod) -> String {
        guard let projected = period.projectedDollars, projected > 0 else {
            return "待补齐"
        }
        return projected.formatted(.number.precision(.fractionLength(0 ... 2))) + "$"
    }
}

private struct ProviderPeriodCard<Content: View>: View {
    let period: GeminiValuationPeriod
    let estimateText: String
    @ViewBuilder let content: () -> Content
    @State private var isExpanded = false
    @State private var isHovered = false

    private var statusText: String {
        period.earlyReset ? "提前重置" : period.end > Date() ? "进行中" : "已结束"
    }

    private var planCaption: String {
        if let plan = period.planTitle, !plan.isEmpty {
            return plan + " · 设备日志外推"
        }
        return "设备日志外推"
    }

    var body: some View {
        VStack(spacing: 0) {
            Button { isExpanded.toggle() } label: {
                rowContent
            }
            .buttonStyle(.plain)
            .onHover { isHovered = $0 }
            .animation(.easeOut(duration: 0.12), value: isHovered)
            .accessibilityValue(isExpanded ? "已展开" : "已收起")
            if isExpanded {
                content()
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 10))
                    .overlay {
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(Color.primary.opacity(0.13), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    }
                    .padding(.top, 5)
                    .padding(.bottom, 7)
                    .transition(.identity)
            }
        }
        .clipped()
        .animation(.codexStatus, value: isExpanded)
    }

    private var rowContent: some View {
        HStack(spacing: 10) {
            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 10, height: 12)
            Text(formatDate(period.start) + " – " + formatDate(period.end))
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("已用 " + period.usedPercent.formatted(.number.precision(.fractionLength(0))) + "%")
                .foregroundStyle(.secondary)
                .frame(width: 62, alignment: .trailing)
            Text(statusText)
                .foregroundStyle(period.earlyReset ? Color.orange : Color.secondary)
                .frame(width: 64)
            VStack(alignment: .trailing, spacing: 3) {
                Text("预计周限总额≈" + estimateText).fontWeight(.semibold)
                Text(planCaption).font(.system(size: 10)).foregroundStyle(.secondary)
            }
            .frame(width: 202, alignment: .trailing)
        }
        .font(.system(size: 12))
        .monospacedDigit()
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .padding(.horizontal, 10)
        .frame(minHeight: 48)
        .background(isHovered ? Color.accentColor.opacity(0.07) : .clear, in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
    }

    private func formatDate(_ value: Date) -> String {
        ProviderPeriodDateFormat.formatter.string(from: value)
    }
}

private struct ProviderPeriodDetails: View {
    let period: GeminiValuationPeriod
    let provider: String
    let priceBook: GeminiPriceBook

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                metricCell("已记录折合价值", dollarsText(period.dollars))
                metricCell("预计周限总额", projectedDetailText)
                metricCell("已采样周限", period.usedPercent.formatted(.number.precision(.fractionLength(1))) + "%")
            }
            HStack {
                metricCell("未缓存输入", tokensText(period.tokens.input))
                metricCell("输出", tokensText(period.tokens.output))
                metricCell("缓存读取", tokensText(period.tokens.cached))
                metricCell("缓存写入", tokensText(period.tokens.cw))
            }
            Text("日志对齐至 \(period.valuedThrough.formatted(date: .abbreviated, time: .shortened)), 对应已用 \(period.usedPercent.formatted(.number.precision(.fractionLength(1))))% 周限")
                .foregroundStyle(.secondary)
            if period.unreliable {
                Text("同一窗口内额度出现回落, 暂停周限外推").foregroundStyle(.orange)
            } else if period.projectedDollars == nil {
                Text("已用周限低于 1% 或已记录折合价值不足 $0.03, 暂不外推周限总额").foregroundStyle(.secondary)
            }
            if !period.models.isEmpty {
                UsageDisclosure(title: "模型用量明细") {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(period.models) { row in
                            modelRow(row)
                        }
                    }
                }
            }
        }
        .font(.caption2)
    }

    private var projectedDetailText: String {
        guard let projected = period.projectedDollars, projected > 0 else {
            return "待补齐"
        }
        return dollarsText(projected)
    }

    private func modelRow(_ row: GeminiModelPeriodBreakdown) -> some View {
        UsageDisclosure(title: row.model + " · " + dollarsText(row.dollars)) {
            HStack {
                metricCell("未缓存输入", tokensText(row.tokens.input))
                metricCell("输出", tokensText(row.tokens.output))
                metricCell("缓存读取", tokensText(row.tokens.cached))
                metricCell("缓存写入", tokensText(row.tokens.cw))
            }
            unitPriceCaption(for: row.model)
        }
    }

    private func unitPriceCaption(for modelName: String) -> some View {
        let rate = priceBook.rate(for: modelName, provider: provider)
        let refTs = min(Date().timeIntervalSince1970, period.valuedThrough.timeIntervalSince1970)
        let unit = rate.unitRates(at: refTs, promptTokens: 0)
        return Text(
            "API 单价 / 百万 Token · 输入 \(currency(unit.inRate)) · 缓存读取 \(currency(unit.crRate)) · 缓存写入 \(currency(unit.cwRate)) · 输出 \(currency(unit.outRate))"
        )
        .foregroundStyle(.secondary)
    }

    private func metricCell(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).foregroundStyle(.secondary)
            Text(text).fontWeight(.semibold).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func dollarsText(_ amount: Double) -> String {
        "≈ " + amount.formatted(.currency(code: "USD").precision(.fractionLength(2)))
    }

    private func currency(_ amount: Double) -> String {
        amount.formatted(.currency(code: "USD").precision(.fractionLength(0 ... 4)))
    }

    private func tokensText(_ count: Int64) -> String {
        "≈ " + count.formatted(.number.notation(.compactName))
    }
}

private enum ProviderPeriodDateFormat {
    static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .autoupdatingCurrent
        formatter.dateFormat = "MM/dd HH:mm"
        return formatter
    }()
}
