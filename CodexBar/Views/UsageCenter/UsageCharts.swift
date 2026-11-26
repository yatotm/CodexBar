import Charts
import SwiftUI

struct UsageDailyChart: View {
    private struct Point: Identifiable {
        let date: Date
        let day: UsageDay
        var id: String {
            day.day
        }
    }

    private let points: [Point]
    var accentColor: Color = ControlCenterPalette.codex
    @State private var hovered: String?
    @State private var pinned: String?

    init(days: [UsageDay], accentColor: Color = ControlCenterPalette.codex) {
        self.accentColor = accentColor
        points = days.compactMap { day in
            CodexDateFormat.dayDate(from: day.day).map { Point(date: $0, day: day) }
        }
    }

    private var selected: Point? {
        points.first { $0.id == (hovered ?? pinned) }
    }

    var body: some View {
        let selection = selected
        VStack(alignment: .leading, spacing: 14) {
            UsageDailyChartHeader(day: selection?.day, accentColor: accentColor)
            if points.isEmpty {
                ContentUnavailableView("所选时间范围内暂无统计", systemImage: "chart.bar.xaxis")
                    .frame(height: 165)
            } else {
                chartContent(selection: selection)
            }
        }
    }

    private func chartContent(selection: Point?) -> some View {
        Chart(points) { point in
            let isPicked = point.id == selection?.id
            BarMark(x: .value("日期", point.date, unit: .day), y: .value("Token", point.day.tokens))
                .foregroundStyle(
                    LinearGradient(
                        colors: [
                            accentColor.opacity(isPicked ? 1.0 : 0.78),
                            accentColor.opacity(isPicked ? 0.80 : 0.45)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .clipShape(UnevenRoundedRectangle(topLeadingRadius: 4, bottomLeadingRadius: 1, bottomTrailingRadius: 1, topTrailingRadius: 4))
                .accessibilityLabel(point.id)
                .accessibilityValue("\(point.day.tokens.formatted()) Token")
            if isPicked {
                RuleMark(x: .value("日期", point.date))
                    .foregroundStyle(accentColor.opacity(0.35))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: .day, count: max(1, points.count / 6))) {
                AxisValueLabel(format: .dateTime.month(.twoDigits).day(.twoDigits))
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
        .chartYAxis {
            AxisMarks { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.6, dash: [3, 3]))
                    .foregroundStyle(Color.primary.opacity(0.08))
                AxisValueLabel {
                    if let count = value.as(Double.self) {
                        Text(count.formatted(.number.notation(.compactName)))
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case let .active(point): hovered = day(at: point, proxy: proxy, geometry: geometry)
                        case .ended: hovered = nil
                        }
                    }
                    .onTapGesture { point in
                        let value = day(at: point, proxy: proxy, geometry: geometry)
                        pinned = pinned == value ? nil : value
                    }
            }
        }
        .frame(height: 165)
    }

    private func day(at point: CGPoint, proxy: ChartProxy, geometry: GeometryProxy) -> String? {
        guard let anchor = proxy.plotFrame else { return nil }
        let frame = geometry[anchor]
        guard frame.contains(point), let date = proxy.value(atX: point.x - frame.minX, as: Date.self) else { return nil }
        return CodexDateFormat.dayString(from: date)
    }
}

struct UsageDailyChartHeader: View {
    let day: UsageDay?
    let accentColor: Color
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ControlCenterSectionHeader(
            title: "每日 Token 趋势",
            subtitle: "悬停查看单日用量, 点击固定或取消",
            symbol: "chart.bar.fill",
            tint: accentColor
        ) {
            if let day {
                HStack(spacing: 8) {
                    Text(day.day)
                        .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(accentColor)
                    Text(day.tokens.formatted(.number.notation(.compactName)) + " Token")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    if let metrics = day.metrics {
                        let input = max(0, metrics.tokens - metrics.output - metrics.cacheRead - metrics.cacheWrite)
                        Text("入 \(input.formatted(.number.notation(.compactName))) · 出 \(metrics.output.formatted(.number.notation(.compactName))) · 缓存 \((metrics.cacheRead + metrics.cacheWrite).formatted(.number.notation(.compactName)))")
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(ControlCenterPalette.pillTrack(colorScheme), in: Capsule(style: .continuous))
            }
        }
        .lineLimit(1)
    }
}

struct UsageTokenBar: View {
    let metrics: UsageMetrics
    let maximum: Int64

    static let colors: [Color] = [
        Color(hex: 0x3B82F6),
        Color(hex: 0x10B981),
        Color(hex: 0x6366F1).opacity(0.75),
        Color(hex: 0xF59E0B).opacity(0.85)
    ]

    var body: some View {
        let parts = [
            max(0, metrics.tokens - metrics.output - metrics.cacheRead - metrics.cacheWrite),
            metrics.output,
            metrics.cacheRead,
            metrics.cacheWrite
        ]
        GeometryReader { geometry in
            HStack(spacing: 1) {
                ForEach(Array(parts.enumerated()), id: \.offset) { index, count in
                    if count > 0 {
                        Rectangle()
                            .fill(Self.colors[index])
                            .frame(width: max(2, geometry.size.width * Double(count) / Double(max(1, maximum))))
                    }
                }
            }
            .clipShape(Capsule())
        }
        .frame(height: 8)
        .background(.primary.opacity(0.05), in: Capsule())
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct UsageBreakdownRow: View {
    let title: String
    let metrics: UsageMetrics
    let maximum: Int64
    let totalSum: Int64
    @State private var isHovered = false
    @Environment(\.colorScheme) private var colorScheme

    private var sharePercent: Int {
        guard totalSum > 0 else { return 0 }
        return Int((Double(metrics.tokens) / Double(totalSum) * 100.0).rounded())
    }

    private var detail: String {
        let input = max(0, metrics.tokens - metrics.output - metrics.cacheRead - metrics.cacheWrite)
        return "\(title) · 合计 \(metrics.tokens.formatted()) Token\n输入 \(input.formatted()) · 输出 \(metrics.output.formatted())"
            + "\n缓存读取 \(metrics.cacheRead.formatted()) · 缓存写入 \(metrics.cacheWrite.formatted())"
    }

    var body: some View {
        HStack(spacing: 14) {
            Text(title)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .frame(width: 170, alignment: .leading)
            UsageTokenBar(metrics: metrics, maximum: maximum)
            HStack(spacing: 6) {
                Text(metrics.tokens.formatted(.number.notation(.compactName)))
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary)
                Text("\(sharePercent)%")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 34, alignment: .trailing)
            }
            .monospacedDigit()
            .frame(width: 102, alignment: .trailing)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            isHovered ? ControlCenterPalette.pillTrack(colorScheme) : .clear,
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .help(detail)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(detail)
    }
}

struct UsageBreakdownView: View {
    let groups: [UsageGroup]
    @Binding var grouping: UsageGrouping

    private var groupingOptions: [ControlCenterPillOption<UsageGrouping>] {
        UsageGrouping.allCases.map { ControlCenterPillOption(value: $0, title: $0.rawValue) }
    }

    var body: some View {
        let activeGroups = groups.filter { $0.metrics.tokens > 0 }
        let maximum = activeGroups.map(\.metrics.tokens).max() ?? 1
        let totalSum = activeGroups.reduce(Int64(0)) { $0 + $1.metrics.tokens }
        VStack(alignment: .leading, spacing: 14) {
            ControlCenterSectionHeader(
                title: "结构与用量分布",
                subtitle: "按维度拆解输入, 输出与缓存占比, 悬浮查看精确数值",
                symbol: "square.stack.3d.up.fill",
                tint: .indigo
            ) {
                ControlCenterPillPicker(options: groupingOptions, selection: $grouping)
            }
            legendRow
            if activeGroups.isEmpty {
                Text("当前筛选条件下暂无分组用量")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                LazyVStack(spacing: 2) {
                    ForEach(activeGroups) { group in
                        UsageBreakdownRow(
                            title: displayName(group.name),
                            metrics: group.metrics,
                            maximum: maximum,
                            totalSum: totalSum
                        )
                    }
                }
            }
        }
    }

    private var legendRow: some View {
        HStack(spacing: 16) {
            ForEach(Array(["未缓存输入", "模型输出", "缓存读取", "缓存写入"].enumerated()), id: \.offset) { index, label in
                HStack(spacing: 5) {
                    Circle().fill(UsageTokenBar.colors[index]).frame(width: 7, height: 7)
                    Text(label).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
    }

    private func displayName(_ name: String) -> String {
        switch name {
        case "codex": "Codex"
        case "claude": "Claude Code"
        case "gemini": "Gemini (agy)"
        case "oauth": "OAuth 订阅"
        case "api": "API 密钥"
        case "unknown", "": "未标记"
        default: name
        }
    }
}
