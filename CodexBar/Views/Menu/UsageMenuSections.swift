import SwiftUI

struct UsageMenuSummaryView: View {
    let dashboard: UsageDashboard
    let onHoverContextChange: (UsageHeatmapHoverContext?) -> Void
    private let days: [UsageHeatmapDay?]
    private let peakTokens: Int
    @State private var selection: UsageHeatmapSelection?
    @State private var screenFrame: CGRect?

    init(
        dashboard: UsageDashboard,
        onHoverContextChange: @escaping (UsageHeatmapHoverContext?) -> Void
    ) {
        self.dashboard = dashboard
        self.onHoverContextChange = onHoverContextChange
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let formatter = ISO8601DateFormatter()
        let counts = Dictionary(dashboard.days.map { ($0.day, $0.tokens) }, uniquingKeysWith: +)
        let days = CodexWeekGrid.dates(columnCount: UsageHeatmap.Metrics.columnCount, calendar: calendar).map { date -> UsageHeatmapDay? in
            guard let date else { return nil }
            let key = String(formatter.string(from: date).prefix(10))
            return UsageHeatmapDay(
                startDate: key,
                tokenState: .available(Int(clamping: counts[key] ?? 0)),
                workflow: .empty(startDate: key)
            )
        }
        self.days = days
        peakTokens = max(1, days.compactMap { $0?.tokensForHeatmap }.max() ?? 0)
    }

    private var hoverContext: UsageHeatmapHoverContext? {
        guard let selection,
              let day = days.compactMap(\.self).first(where: { $0.id == selection.day.id }) else { return nil }
        return UsageHeatmapHoverContext(
            day: day, showsWorkflow: false, alignmentScreenFrame: screenFrame,
            preferredSide: UsageHeatmap.Metrics.preferredDetailSide(for: selection.column),
            peakTokens: peakTokens,
            recordedDay: dashboard.days.first { $0.day == day.id } ?? UsageDay(day: day.id, tokens: 0)
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            let streaks = dashboard.streaks()
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                tokenMetric("已采集", value: dashboard.totals.tokens)
                tokenMetric("单日峰值", value: dashboard.days.map(\.tokens).max() ?? 0)
                textMetric("当前连胜", value: "\(streaks.current)天")
                textMetric("最长连胜", value: "\(streaks.longest)天")
                textMetric("最长单轮", value: dashboard.longestTurnMs.map {
                    CodexDurationFormat.activityText(for: Double($0) / 1000)
                } ?? "--")
            }
            .help("从最多 210 天的设备日志计算, 不代表账号全时累计; 最长单轮只采用日志明确记录的时长")
            UsageHeatmap(
                days: days, selection: $selection, peakTokens: peakTokens,
                onScreenFrameChange: { screenFrame = $0 }
            )
        }
        .padding(MenuMetrics.panelPadding)
        .liquidGlassSurface(cornerRadius: MenuMetrics.panelCornerRadius)
        .onChange(of: hoverContext) { _, context in onHoverContextChange(context) }
        .onDisappear { onHoverContextChange(nil) }
    }

    private func tokenMetric(_ title: String, value: Int64) -> some View {
        VStack(spacing: 2) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            TokenCountText(tokens: Int(clamping: value))
        }.frame(maxWidth: .infinity)
    }

    private func textMetric(_ title: String, value: String) -> some View {
        VStack(spacing: 2) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.caption.monospacedDigit().weight(.semibold))
                .lineLimit(1).minimumScaleFactor(0.7)
        }.frame(maxWidth: .infinity)
    }
}

struct ClaudeMenuQuotaView: View {
    let observation: UsageQuotaObservation?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Claude 额度").font(.caption.weight(.semibold))
                Spacer()
                Text(observation.map { Date(timeIntervalSince1970: $0.observedAt).formatted(date: .omitted, time: .shortened) + " 记录" } ?? "未记录")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            QuotaRow(window: window(named: "5h", kind: .primary, minutes: 300))
            QuotaRow(window: window(named: "7d", kind: .secondary, minutes: 10080))
        }
        .padding(MenuMetrics.panelPadding)
        .liquidGlassSurface(cornerRadius: MenuMetrics.panelCornerRadius)
        .help("只读各机器已有额度缓存, 显示最新记录; 缺少重置时间时显示 --, 不推算新窗口用量")
    }

    private func window(named name: String, kind: QuotaWindowKind, minutes: Int) -> QuotaWindow {
        let recorded = observation?.windows.first { $0.name == name }
        let now = Date().timeIntervalSince1970
        let isFresh = observation.map { now >= $0.observedAt } == true
            && recorded.map { window in
                if let reset = window.resetsAt {
                    return reset > now
                }
                return now - (observation?.observedAt ?? 0) < Double(minutes * 60)
            } == true
        return QuotaWindow(
            kind: kind, windowDurationMins: minutes,
            usedPercent: isFresh ? recorded.map { Int($0.usedPercent.rounded()) } : nil,
            resetsAt: isFresh ? recorded?.resetsAt.map { Date(timeIntervalSince1970: $0) } : nil
        )
    }
}

struct UsageMenuFooter: View {
    @ObservedObject var viewModel: UsageCenterViewModel
    let onOpenDetails: () -> Void
    @State private var isExpanded = false

    private var needsAttention: Bool {
        viewModel.error != nil || viewModel.menuSources.contains { source in
            guard let status = viewModel.statuses[source.id], let lastSuccess = status.lastSuccess else { return true }
            return status.error != nil || !status.warnings.isEmpty || Date().timeIntervalSince(lastSuccess) > 900
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Button { isExpanded.toggle() } label: {
                    Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isExpanded ? "收起设备详情" : "展开设备详情")
                HStack(spacing: 8) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .frame(width: 10, height: 10)
                        .transaction { $0.animation = nil
                            $0.disablesAnimations = true
                        }
                        .allowsHitTesting(false)
                    Text(viewModel.isRefreshing ? "正在更新…" : "\(viewModel.menuSources.count) 台设备 · \(needsAttention ? "待更新" : "已更新")")
                        .foregroundStyle(needsAttention ? Color.orange : Color.secondary)
                        .allowsHitTesting(false)
                    Button { viewModel.refresh() } label: {
                        Image(systemName: "arrow.clockwise.circle").font(.system(size: 13))
                    }
                    .buttonStyle(.plain).disabled(viewModel.isRefreshing).help("刷新设备统计")
                    Spacer()
                    Button(action: onOpenDetails) {
                        HStack(spacing: 3) {
                            Text("用量详情")
                            Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold))
                        }
                    }
                    .buttonStyle(.plain).help("打开用量中心")
                }
                .padding(.horizontal, MenuMetrics.panelPadding)
                .transaction { $0.animation = nil }
            }.frame(height: 28)
            UsageReveal(isExpanded: isExpanded, animatesContent: false) {
                VStack(spacing: 8) {
                    LiquidGlassDivider()
                    ForEach(viewModel.menuSources) { source in
                        HStack {
                            Image(systemName: source.transport == .local ? "laptopcomputer" : "server.rack")
                            Text(source.name).lineLimit(1)
                            Spacer()
                            let tokens = viewModel.menuDashboard?.groups.first { $0.name == source.name }?.metrics.tokens
                            if let tokens {
                                TokenCountText(tokens: Int(clamping: tokens))
                            } else {
                                Text("--")
                            }
                        }
                        .foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("保留期内已采集 · 已去重").foregroundStyle(.tertiary)
                        Spacer()
                    }
                }.padding(.horizontal, MenuMetrics.panelPadding).padding(.bottom, 8)
            }
        }
        .font(.caption2)
        .liquidGlassSurface(cornerRadius: MenuMetrics.panelCornerRadius)
    }
}
