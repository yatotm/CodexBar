import SwiftUI

struct UsagePeriodCard<Content: View>: View {
    let period: UsageAnalyticsPeriod
    let estimate: String
    let isReference: Bool
    let planTitle: String
    @ViewBuilder let content: () -> Content
    @State private var isExpanded = false
    @State private var isHovered = false

    private var status: String {
        period.earlyReset ? "提前重置" : period.end > Date() ? "进行中" : "已结束"
    }

    private func date(_ value: Date) -> String {
        UsagePeriodDateFormat.formatter.string(from: value)
    }

    var body: some View {
        VStack(spacing: 0) {
            Button { isExpanded.toggle() } label: {
                HStack(spacing: 10) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 10, height: 12)
                    Text(date(period.start) + " – " + date(period.end))
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text("已用 " + period.usedPercent.formatted(.number.precision(.fractionLength(0))) + "%")
                        .foregroundStyle(.secondary)
                        .frame(width: 62, alignment: .trailing)
                    Text(status)
                        .foregroundStyle(period.earlyReset ? Color.orange : Color.secondary)
                        .frame(width: 64)
                    VStack(alignment: .trailing, spacing: 3) {
                        Text("预计周限总额≈" + estimate).fontWeight(.semibold)
                        Text((planTitle.isEmpty ? "" : planTitle + " · ") + (isReference ? "额度参考" : "用量推算"))
                            .font(.system(size: 10)).foregroundStyle(.secondary)
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
