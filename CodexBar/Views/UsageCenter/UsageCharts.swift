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
    @State private var hovered: String?
    @State private var pinned: String?

    init(days: [UsageDay]) {
        points = days.compactMap { day in
            CodexDateFormat.dayDate(from: day.day).map { Point(date: $0, day: day) }
        }
    }

    private var selected: Point? {
        points.first { $0.id == (hovered ?? pinned) }
    }

    var body: some View {
        let selection = selected
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("每日用量").font(.caption.weight(.semibold))
                Spacer()
                if let point = selection {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("\(point.id) · \(point.day.tokens.formatted()) Token").fontWeight(.medium)
                        if let metrics = point.day.metrics {
                            let input = max(0, metrics.tokens - metrics.output - metrics.cacheRead - metrics.cacheWrite)
                            Text("输入 \(input.formatted()) · 输出 \(metrics.output.formatted()) · 缓存读 \(metrics.cacheRead.formatted()) · 写 \(metrics.cacheWrite.formatted())")
                                .foregroundStyle(.secondary)
                                .lineLimit(1).minimumScaleFactor(0.75)
                        }
                    }.font(.caption2.monospacedDigit())
                } else {
                    Text("悬浮查看 · 点击固定").font(.caption2).foregroundStyle(.tertiary)
                }
            }.frame(height: 30)
            if points.isEmpty {
                ContentUnavailableView("暂无统计", systemImage: "chart.bar")
                    .frame(height: 145)
            } else {
                Chart(points) { point in
                    BarMark(x: .value("日期", point.date, unit: .day), y: .value("Token", point.day.tokens))
                        .foregroundStyle(.blue.opacity(point.id == selection?.id ? 0.95 : 0.60).gradient)
                        .cornerRadius(3)
                        .accessibilityLabel(point.id)
                        .accessibilityValue("\(point.day.tokens.formatted()) Token")
                    if point.id == selection?.id {
                        RuleMark(x: .value("日期", point.date)).foregroundStyle(.blue.opacity(0.35))
                    }
                }
                .chartXAxis {
                    AxisMarks(values: .stride(by: .day, count: max(1, points.count / 6))) {
                        AxisGridLine()
                        AxisValueLabel(format: .dateTime.month(.twoDigits).day(.twoDigits))
                    }
                }
                .chartYAxis {
                    AxisMarks { value in
                        AxisGridLine()
                        AxisValueLabel {
                            if let count = value.as(Double.self) {
                                Text(count.formatted(.number.notation(.compactName)))
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
                .frame(height: 145)
            }
        }
    }

    private func day(at point: CGPoint, proxy: ChartProxy, geometry: GeometryProxy) -> String? {
        guard let anchor = proxy.plotFrame else { return nil }
        let frame = geometry[anchor]
        guard frame.contains(point), let date = proxy.value(atX: point.x - frame.minX, as: Date.self) else { return nil }
        return CodexDateFormat.dayString(from: date)
    }
}

struct UsageTokenBar: View {
    let metrics: UsageMetrics
    let maximum: Int64

    static let colors: [Color] = [.blue.opacity(0.7), .teal.opacity(0.7), .indigo.opacity(0.55), .orange.opacity(0.65)]

    var body: some View {
        let parts = [
            max(0, metrics.tokens - metrics.output - metrics.cacheRead - metrics.cacheWrite),
            metrics.output,
            metrics.cacheRead,
            metrics.cacheWrite
        ]
        GeometryReader { geometry in
            HStack(spacing: 0) {
                ForEach(Array(parts.enumerated()), id: \.offset) { index, count in
                    Rectangle().fill(Self.colors[index])
                        .frame(width: geometry.size.width * Double(count) / Double(max(1, maximum)))
                }
            }
            .clipShape(Capsule())
        }
        .frame(height: 7)
        .background(.primary.opacity(0.035), in: Capsule())
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct UsageBreakdownRow: View {
    let title: String
    let metrics: UsageMetrics
    let maximum: Int64
    @State private var isHovered = false

    private var detail: String {
        let input = max(0, metrics.tokens - metrics.output - metrics.cacheRead - metrics.cacheWrite)
        return "\(title) · 合计 \(metrics.tokens.formatted()) Token\n输入 \(input.formatted())\n输出 \(metrics.output.formatted())"
            + "\n缓存读取 \(metrics.cacheRead.formatted())\n缓存写入 \(metrics.cacheWrite.formatted())"
    }

    var body: some View {
        HStack(spacing: 16) {
            Text(title).font(.caption).lineLimit(1).frame(width: 155, alignment: .leading)
            UsageTokenBar(metrics: metrics, maximum: maximum).padding(.trailing, 16)
        }
        .padding(.horizontal, 8).padding(.vertical, 9)
        .background(isHovered ? Color.primary.opacity(0.045) : .clear, in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .overlay(alignment: .bottomTrailing) {
            if isHovered {
                Text(detail)
                    .font(.caption.monospacedDigit())
                    .padding(10)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.primary.opacity(0.08)))
                    .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
                    .fixedSize()
                    .offset(y: -32)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .zIndex(isHovered ? 1 : 0)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(detail)
    }
}

struct UsageBreakdownView: View {
    let groups: [UsageGroup]
    @Binding var grouping: UsageGrouping

    var body: some View {
        let maximum = groups.map(\.metrics.tokens).max() ?? 1
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("用量分布").font(.caption.weight(.semibold))
                Spacer()
                Picker("按", selection: $grouping) {
                    ForEach(UsageGrouping.allCases) { Text($0.rawValue).tag($0) }
                }.frame(width: 155)
            }
            HStack(spacing: 14) {
                ForEach(Array(["输入", "输出", "缓存读取", "缓存写入"].enumerated()), id: \.offset) { index, label in
                    Label { Text(label) } icon: { Circle().fill(UsageTokenBar.colors[index]).frame(width: 6, height: 6) }
                }
            }.font(.caption2).foregroundStyle(.secondary)
                .help("输入不含已单列的缓存; 条长表示 Token 数, 悬浮显示精确数值")
            LazyVStack(spacing: 2) {
                ForEach(groups.filter { $0.metrics.tokens > 0 }) { group in
                    UsageBreakdownRow(title: displayName(group.name), metrics: group.metrics, maximum: maximum)
                }
            }
        }
    }

    private func displayName(_ name: String) -> String {
        switch name {
        case "codex": "Codex"
        case "claude": "Claude"
        case "oauth": "OAuth"
        case "api": "API"
        case "unknown", "": "未知"
        default: name
        }
    }
}
