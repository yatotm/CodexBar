import SwiftUI

struct UsagePeriodCard<Content: View>: View {
    let period: UsageAnalyticsPeriod
    let estimate: String
    let isReference: Bool
    let planTitle: String
    @ViewBuilder let content: () -> Content
    @State private var isExpanded = false
    @State private var isHovered = false
    @Environment(\.colorScheme) private var colorScheme

    private var statusTitle: String {
        period.earlyReset ? "提前重置" : period.end > Date() ? "进行中" : "已结束"
    }

    private var statusColor: Color {
        if period.earlyReset {
            return .orange
        }
        return period.end > Date() ? ControlCenterPalette.codex : .secondary
    }

    private func date(_ value: Date) -> String {
        UsagePeriodDateFormat.formatter.string(from: value)
    }

    var body: some View {
        VStack(spacing: 0) {
            Button { isExpanded.toggle() } label: {
                rowHeader
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

    private var rowHeader: some View {
        HStack(spacing: 12) {
            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 12, height: 12)
            Text(date(period.start) + " – " + date(period.end))
                .font(.system(size: 12.5, weight: .medium, design: .monospaced))
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
            usageProgressPill
            ControlCenterStatusBadge(title: statusTitle, color: statusColor)
                .frame(width: 78, alignment: .trailing)
            VStack(alignment: .trailing, spacing: 2) {
                Text("预计周限 ≈ " + estimate)
                    .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary)
                if !planTitle.isEmpty || isReference {
                    Text([planTitle, isReference ? "额度参考" : ""].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
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

    private var usageProgressPill: some View {
        let clamped = min(max(period.usedPercent, 0), 100)
        return HStack(spacing: 7) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.08))
                    Capsule()
                        .fill(ControlCenterPalette.codex.opacity(0.85))
                        .frame(width: geo.size.width * (clamped / 100.0))
                }
            }
            .frame(width: 48, height: 5)
            Text(period.usedPercent.formatted(.number.precision(.fractionLength(0))) + "%")
                .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 36, alignment: .trailing)
        }
    }
}

private enum UsagePeriodDateFormat {
    static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .autoupdatingCurrent
        formatter.dateFormat = "MM/dd HH:mm"
        return formatter
    }()
}
