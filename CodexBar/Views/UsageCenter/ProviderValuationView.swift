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

    private var accent: Color {
        ControlCenterPalette.providerAccent(provider)
    }

    private var symbolName: String {
        provider == "gemini" ? "sparkles" : "bolt.horizontal.circle.fill"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            headerBar
            if hasOfflineNodes {
                Label("部分开启该渠道的远程节点离线, 待节点上线补传后自动对齐周限估值", systemImage: "wifi.exclamationmark")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.orange)
            }
            if periods.isEmpty {
                emptyPlaceholder
            } else {
                VStack(spacing: 4) {
                    ForEach(periods.prefix(visibleCount)) { period in
                        ProviderPeriodCard(
                            period: period,
                            accent: accent,
                            estimateText: projectedText(for: period)
                        ) {
                            ProviderPeriodDetails(period: period, provider: provider, priceBook: priceBook)
                        }
                    }
                }
            }
            if periods.count > visibleCount {
                Button("展开更多历史周期") { visibleCount += 8 }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(accent)
            }
            HStack {
                Text("按标准 API 单价 (含促销期与长上下文阶梯) 及已记录 7d 额度消耗占比外推周限总额")
                Spacer()
                Text("价格快照 \(priceBook.asOf)")
            }
            .font(.system(size: 11))
            .foregroundStyle(.tertiary)
        }
        .padding(16)
        .usageCenterCard()
    }

    private var headerBar: some View {
        ControlCenterSectionHeader(
            title: title,
            subtitle: subtitle,
            symbol: symbolName,
            tint: accent
        ) {
            HStack(spacing: 4) {
                if isRefreshing {
                    ProgressView().controlSize(.mini).padding(.trailing, 4)
                }
                Link(destination: pricingURL) {
                    Image(systemName: "arrow.up.right.square")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .help("查看官方 API 定价文档")
                ControlCenterIconButton(
                    symbol: "arrow.clockwise",
                    helpText: "刷新价值统计",
                    isDisabled: isRefreshing,
                    action: onRefresh
                )
            }
        }
    }

    private var emptyPlaceholder: some View {
        HStack(spacing: 10) {
            Image(systemName: "clock.badge.questionmark")
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
            Text(isRefreshing ? "正在计算周期估值…" : "等待包含 7d 重置时间的额度记录与模型样本; 新开交互式会话即可自动捕获")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .usageCenterInset(cornerRadius: 9)
    }

    private func projectedText(for period: GeminiValuationPeriod) -> String {
        guard let projected = period.projectedDollars, projected > 0 else {
            return "待补齐"
        }
        return "$" + projected.formatted(.number.precision(.fractionLength(0 ... 2)))
    }
}

private struct ProviderPeriodCard<Content: View>: View {
    let period: GeminiValuationPeriod
    let accent: Color
    let estimateText: String
    @ViewBuilder let content: () -> Content
    @State private var isExpanded = false
    @State private var isHovered = false
    @Environment(\.colorScheme) private var colorScheme

    private var statusText: String {
        period.earlyReset ? "提前重置" : period.end > Date() ? "进行中" : "已结束"
    }

    private var statusColor: Color {
        if period.earlyReset {
            return .orange
        }
        return period.end > Date() ? accent : .secondary
    }

    private var planCaption: String {
        if let plan = period.planTitle, !plan.isEmpty {
            return plan + " · 当前账号设备日志外推"
        }
        return "当前账号设备日志外推"
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
                    .usageCenterInset(cornerRadius: 10)
                    .padding(.top, 6)
                    .padding(.bottom, 6)
                    .transition(.identity)
            }
        }
        .clipped()
        .animation(.codexStatus, value: isExpanded)
    }

    private var rowContent: some View {
        let clamped = min(max(period.usedPercent, 0), 100)
        return HStack(spacing: 12) {
            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 12, height: 12)
            Text(formatDate(period.start) + " – " + formatDate(period.end))
                .font(.system(size: 12.5, weight: .medium, design: .monospaced))
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 7) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.08))
                        Capsule()
                            .fill(accent.opacity(0.85))
                            .frame(width: geo.size.width * (clamped / 100.0))
                    }
                }
                .frame(width: 48, height: 5)
                Text(period.usedPercent.formatted(.number.precision(.fractionLength(0))) + "%")
                    .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 36, alignment: .trailing)
            }
            ControlCenterStatusBadge(title: statusText, color: statusColor)
                .frame(width: 78, alignment: .trailing)
            VStack(alignment: .trailing, spacing: 2) {
                Text("预计周限 ≈ " + estimateText)
                    .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary)
                Text(planCaption)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
            .frame(width: 196, alignment: .trailing)
        }
        .monospacedDigit()
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .padding(.horizontal, 12)
        .frame(minHeight: 50)
        .background(
            isHovered || isExpanded ? ControlCenterPalette.pillTrack(colorScheme) : .clear,
            in: RoundedRectangle(cornerRadius: 9, style: .continuous)
        )
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
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                metricCell("已记录折合价值", dollarsText(period.dollars))
                metricCell("预计周限总额", projectedDetailText)
                metricCell("已采样周限", period.usedPercent.formatted(.number.precision(.fractionLength(1))) + "%")
            }
            HStack(spacing: 12) {
                metricCell("未缓存输入", tokensText(period.tokens.input))
                metricCell("模型输出", tokensText(period.tokens.output))
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
                Divider().opacity(0.5)
                UsageDisclosure(title: "按模型查看估值明细 (\(period.models.count))") {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(period.models) { row in
                            modelRow(row)
                        }
                    }
                }
            }
        }
        .font(.system(size: 11.5))
    }

    private var projectedDetailText: String {
        guard let projected = period.projectedDollars, projected > 0 else {
            return "待补齐"
        }
        return dollarsText(projected)
    }

    private func modelRow(_ row: GeminiModelPeriodBreakdown) -> some View {
        UsageDisclosure(title: row.model + " · " + dollarsText(row.dollars)) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 12) {
                    metricCell("未缓存输入", tokensText(row.tokens.input))
                    metricCell("模型输出", tokensText(row.tokens.output))
                    metricCell("缓存读取", tokensText(row.tokens.cached))
                    metricCell("缓存写入", tokensText(row.tokens.cw))
                }
                unitPriceCaption(for: row.model)
            }
        }
    }

    private func unitPriceCaption(for modelName: String) -> some View {
        let rate = priceBook.rate(for: modelName, provider: provider)
        let refTs = min(Date().timeIntervalSince1970, period.valuedThrough.timeIntervalSince1970)
        let unit = rate.unitRates(at: refTs, promptTokens: 0)
        return Text(
            "API 单价 / 百万 Token · 输入 \(currency(unit.inRate)) · 缓存读取 \(currency(unit.crRate)) · 缓存写入 \(currency(unit.cwRate)) · 输出 \(currency(unit.outRate))"
        )
        .font(.system(size: 11))
        .foregroundStyle(.tertiary)
    }

    private func metricCell(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 11)).foregroundStyle(.secondary)
            Text(text).font(.system(size: 13, weight: .semibold, design: .rounded)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.75)
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
