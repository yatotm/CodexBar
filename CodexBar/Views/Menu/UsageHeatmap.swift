import AppKit
import SwiftUI

/// hover 详情面板需要的完整上下文, 包括屏幕坐标和峰值 token
nonisolated struct UsageHeatmapHoverContext: Equatable {
    let period: UsageHeatmapPeriod
    let showsWorkflow: Bool
    let alignmentScreenFrame: CGRect?
    let preferredSide: UsageHeatmapDetailSide
    let peakTokens: Int
    var recordedDay: UsageDay?

    var day: UsageHeatmapDay {
        period.day
    }

    var showsExtendedDetails: Bool {
        showsWorkflow || recordedDay != nil
    }
}

nonisolated enum UsageHeatmapDetailSide: Equatable {
    case left
    case right
}

/// 选择跟随日期和模式, 跨日刷新后重新计算网格位置
nonisolated struct UsageHeatmapSelection: Equatable {
    let dateID: String
    let mode: UsageHeatmapMode

    func column(in days: [UsageHeatmapDay?]) -> Int? {
        days.firstIndex { $0?.id == dateID }.map { $0 / CodexWeekGrid.rowCount }
    }

    func period(in days: [UsageHeatmapDay?], weeks: [UsageHeatmapPeriod?]) -> UsageHeatmapPeriod? {
        guard let index = days.firstIndex(where: { $0?.id == dateID }) else { return nil }
        switch mode {
        case .daily: return days[index].map(UsageHeatmapPeriod.init(day:))
        case .weekly:
            let column = index / CodexWeekGrid.rowCount
            return weeks.indices.contains(column) ? weeks[column] : nil
        }
    }

    static func at(column: Int, row: Int, in days: [UsageHeatmapDay?], mode: UsageHeatmapMode) -> Self? {
        guard column >= 0, (0 ..< CodexWeekGrid.rowCount).contains(row) else { return nil }
        let index = column * CodexWeekGrid.rowCount + (mode == .daily ? row : 0)
        guard days.indices.contains(index), let day = days[index] else { return nil }
        return Self(dateID: day.id, mode: mode)
    }
}

// MARK: - 摘要区

/// token 摘要和近 30 周热力图的组合区
struct UsageSummaryView: View {
    let usage: CodexUsageSnapshot?
    let isStale: Bool
    let showsWorkflow: Bool
    let onHoverContextChange: (UsageHeatmapHoverContext?) -> Void
    private let days: [UsageHeatmapDay?]
    private let weeks: [UsageHeatmapPeriod?]
    private let peakTokens: Int
    private let peakWeeklyTokens: Int
    private let recordedDays: [UsageDay]
    @State private var hoverSelection: UsageHeatmapSelection?
    @State private var heatmapScreenFrame: CGRect?

    init(
        usage: CodexUsageSnapshot?,
        workflow: WorkflowSnapshot,
        showsWorkflow: Bool,
        isStale: Bool = false,
        recordedDays: [UsageDay] = [],
        onHoverContextChange: @escaping (UsageHeatmapHoverContext?) -> Void = { _ in }
    ) {
        self.usage = usage
        self.isStale = isStale
        self.showsWorkflow = showsWorkflow
        self.onHoverContextChange = onHoverContextChange
        self.recordedDays = recordedDays

        let days = UsageHeatmapDay.grid(
            usage: usage,
            workflow: workflow,
            showsWorkflow: showsWorkflow,
            columnCount: UsageHeatmap.Metrics.columnCount,
            today: Date()
        )
        self.days = days
        let weeks = UsageHeatmapPeriod.weeks(in: days)
        self.weeks = weeks
        peakTokens = max(days.lazy.compactMap { $0?.tokensForHeatmap }.max() ?? 0, 1)
        peakWeeklyTokens = max(weeks.lazy.compactMap { $0?.tokensForHeatmap }.max() ?? 0, 1)
    }

    var body: some View {
        content
            .markStale(isStale)
            .padding(MenuMetrics.panelPadding)
            .liquidGlassSurface(cornerRadius: MenuMetrics.panelCornerRadius)
            .onAppear {
                clearHover()
            }
            .onDisappear {
                clearHover()
            }
            .onChange(of: days) { _, newDays in
                refreshHoveredDay(from: newDays)
            }
            .onChange(of: hoverContext) { _, context in
                onHoverContextChange(context)
            }
            .animation(Metrics.statusAnimation, value: usage)
            .animation(Metrics.statusAnimation, value: days)
    }

    @ViewBuilder
    private var content: some View {
        if usage?.hasAppServerData == true || showsWorkflow {
            VStack(alignment: .leading, spacing: 8) {
                metricsGrid

                if usage?.hasDailyUsageBuckets == true || showsWorkflow {
                    UsageHeatmap(
                        days: days,
                        weeks: weeks,
                        selection: $hoverSelection,
                        peakTokens: peakTokens,
                        peakWeeklyTokens: peakWeeklyTokens,
                        onScreenFrameChange: { frame in
                            heatmapScreenFrame = frame
                        }
                    )
                } else {
                    dailyUsageUnavailable
                }
            }
        } else {
            Text("common.empty.no-data")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, MenuMetrics.loadingVerticalPadding)
        }
    }

    private var metricsGrid: some View {
        HStack(alignment: .firstTextBaseline, spacing: Metrics.metricSpacing) {
            tokenMetric(label: "usage.summary.lifetime-tokens", value: usage?.summary.lifetimeTokens)
            tokenMetric(label: "usage.summary.peak-tokens", value: usage?.summary.peakDailyTokens)
            textMetric(
                label: "usage.summary.current-streak",
                value: Self.dayText(usage?.summary.currentStreakDays)
            )
            textMetric(
                label: "usage.summary.longest-streak",
                value: Self.dayText(usage?.summary.longestStreakDays)
            )
            textMetric(
                label: "usage.summary.longest-chat",
                value: Self.durationText(seconds: usage?.summary.longestRunningTurnSec)
            )
        }
    }

    private func tokenMetric(label: LocalizedStringResource, value: Int?) -> some View {
        metric(label: label) {
            if let value {
                TokenCountText(tokens: value)
                    .minimumScaleFactor(0.8)
            } else {
                Text(verbatim: "--")
                    .font(.caption.monospacedDigit().weight(.semibold))
            }
        }
    }

    private var dailyUsageUnavailable: some View {
        Text("usage.heatmap.no-data")
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .center)
            .frame(height: UsageHeatmap.Metrics.height)
    }

    private func textMetric(label: LocalizedStringResource, value: String) -> some View {
        metric(label: label) {
            Text(value)
                .font(.caption.monospacedDigit().weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
    }

    private func metric(
        label: LocalizedStringResource,
        @ViewBuilder value: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)

            value()
                .frame(maxWidth: .infinity, alignment: .center)
        }
        .frame(maxWidth: .infinity)
    }

    private static func dayText(_ days: Int?) -> String {
        guard let days else {
            return "--"
        }

        return String(localized: "duration.days-compact", defaultValue: "\(max(days, 0), specifier: "%lld")")
    }

    private static func durationText(seconds: Int?) -> String {
        guard let seconds else {
            return "--"
        }

        return CodexDurationFormat.activityText(for: TimeInterval(seconds))
    }

    private enum Metrics {
        static let metricSpacing: CGFloat = 8
        static let statusAnimation = Animation.codexStatus
    }

    private var hoverContext: UsageHeatmapHoverContext? {
        // 详情面板由控制器显示, SwiftUI 这里只负责传递屏幕坐标和数据
        guard let selection = hoverSelection,
              let column = selection.column(in: days),
              let period = selection.period(in: days, weeks: weeks) else { return nil }
        let hasRecordedDays = recordedDays.contains { period.dayKeys.contains($0.day) }
        return UsageHeatmapHoverContext(
            period: period,
            showsWorkflow: showsWorkflow && !hasRecordedDays,
            alignmentScreenFrame: heatmapScreenFrame,
            preferredSide: UsageHeatmap.Metrics.preferredDetailSide(for: column),
            peakTokens: selection.mode == .daily ? peakTokens : peakWeeklyTokens,
            recordedDay: hasRecordedDays ? period.recordedUsage(in: recordedDays) : nil
        )
    }

    private func refreshHoveredDay(from days: [UsageHeatmapDay?]) {
        guard let hoverSelection else {
            return
        }

        guard hoverSelection.period(in: days, weeks: weeks) != nil else {
            withAnimation(Metrics.statusAnimation) {
                self.hoverSelection = nil
            }
            return
        }
    }

    private func clearHover() {
        hoverSelection = nil
        onHoverContextChange(nil)
    }
}

// MARK: - 热力图与 hover 吸附

/// 近 30 周 token 热力图, hover 时把指针吸附到最近的有效日期格
struct UsageHeatmap: View {
    let days: [UsageHeatmapDay?]
    let weeks: [UsageHeatmapPeriod?]
    let onScreenFrameChange: (CGRect?) -> Void
    @Binding var selection: UsageHeatmapSelection?
    @AppStorage(UsageHeatmapMode.preferenceKey) private var mode = UsageHeatmapMode.daily
    @Environment(\.mainPanelEntranceAnimationsEnabled) private var animatesEntrance
    @State private var areSquaresRevealed = false
    @State private var entranceStartedAt: TimeInterval?
    @State private var snapSelection: UsageHeatmapSelection?
    @State private var hoverClearTask: Task<Void, Never>?
    @State private var isModeHovered = false
    private let peakTokens: Int
    private let peakWeeklyTokens: Int

    init(
        days: [UsageHeatmapDay?],
        weeks: [UsageHeatmapPeriod?],
        selection: Binding<UsageHeatmapSelection?>,
        peakTokens: Int,
        peakWeeklyTokens: Int,
        onScreenFrameChange: @escaping (CGRect?) -> Void = { _ in }
    ) {
        self.days = days
        self.weeks = weeks
        self.onScreenFrameChange = onScreenFrameChange
        _selection = selection
        self.peakTokens = peakTokens
        self.peakWeeklyTokens = peakWeeklyTokens
    }

    var body: some View {
        heatmapGrid
            .frame(height: Metrics.height)
            .background {
                ScreenFrameReader(onChange: onScreenFrameChange)
            }
            .task(id: mode) {
                areSquaresRevealed = false
                await revealSquares()
            }
            .onChange(of: mode) { _, _ in
                cancelHoverClearTask()
                snapSelection = nil
                selection = nil
            }
            .onDisappear {
                cancelHoverClearTask()
                snapSelection = nil
                selection = nil
                onScreenFrameChange(nil)
            }
    }

    private var heatmapGrid: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                HStack(spacing: 4) {
                    Text(LocalizedStringResource("usage.heatmap.past-weeks", defaultValue: "\(Metrics.columnCount, specifier: "%lld")"))
                    Text(verbatim: "·")
                    Button {
                        mode = mode == .daily ? .weekly : .daily
                    } label: {
                        Text(modeTitle)
                            .padding(.horizontal, 3)
                            .background(Color.primary.opacity(isModeHovered ? 0.08 : 0), in: RoundedRectangle(cornerRadius: 4))
                    }
                    .buttonStyle(.plain)
                    .onHover { isModeHovered = $0 }
                    .help(String(localized: "usage.heatmap.switch-mode", defaultValue: "点击切换日/周视图"))
                }
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
                .fixedSize()

                Spacer()

                if let dateRangeText {
                    Text(dateRangeText)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }

            HStack(alignment: .top, spacing: Metrics.squareSpacing) {
                ForEach(0 ..< Metrics.columnCount, id: \.self) { column in
                    VStack(spacing: Metrics.squareSpacing) {
                        ForEach(0 ..< Metrics.rowCount, id: \.self) { row in
                            gridSquare(column: column, row: row)
                                .opacity(showsSquares ? 1 : 0)
                                .scaleEffect(showsSquares ? 1 : Metrics.entranceScale)
                                .animation(
                                    entranceAnimation(column: column, row: row),
                                    value: showsSquares
                                )
                        }
                    }
                }
            }
            .frame(width: Metrics.totalWidth, height: Metrics.gridHeight, alignment: .topLeading)
            .contentShape(Rectangle())
            .onContinuousHover(coordinateSpace: .local) { phase in
                switch phase {
                case let .active(point):
                    updatePointerLocation(point)
                case .ended:
                    scheduleDeactivate()
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var dateRangeText: String? {
        let visiblePeriods = mode == .daily ? days.compactMap { $0.map(UsageHeatmapPeriod.init(day:)) } : weeks.compactMap(\.self)
        guard let firstDate = visiblePeriods.first?.day.startDate,
              let lastDate = visiblePeriods.last?.endDate else { return nil }

        let firstText = localDayText(firstDate)
        let lastText = localDayText(lastDate)
        return String(localized: "date-range.closed", defaultValue: "\(firstText)\(lastText)")
    }

    private var modeTitle: String {
        mode == .daily
            ? String(localized: "usage.heatmap.daily-data", defaultValue: "日数据")
            : String(localized: "usage.heatmap.weekly-data", defaultValue: "周数据")
    }

    @ViewBuilder
    private func gridSquare(column: Int, row: Int) -> some View {
        let index = column * Metrics.rowCount + row
        let period = mode == .daily
            ? (days.indices.contains(index) ? days[index].map(UsageHeatmapPeriod.init(day:)) : nil)
            : (weeks.indices.contains(column) ? weeks[column] : nil)
        if let period {
            let target = UsageHeatmapSelection(dateID: period.day.id, mode: mode)
            let isFilled = row >= Metrics.rowCount - period.filledRowCount(peakTokens: peakWeeklyTokens)
            let state = mode == .daily ? period.day.tokenState
                : period.day.tokenCount.map { UsageHeatmapTokenState.available(isFilled ? $0 : 0) } ?? period.day.tokenState
            let tokenLabel = period.day.tokenCount.map { "\($0) Token" } ?? String(localized: "common.empty.no-data")
            UsageHeatmapSquare(
                tokenState: state,
                percent: mode == .daily ? Double(period.tokensForHeatmap) / Double(peakTokens) : isFilled ? 1 : 0,
                isHovered: snapSelection == target
            )
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(period.day.startDate)\(period.isWeekly ? " ~ " + period.endDate : ""), \(tokenLabel)")
            .accessibilityAddTraits(.isButton)
            .accessibilityHidden(mode == .weekly && row != 0)
            .accessibilityAction { select(target) }
            .onTapGesture { select(target) }
        } else {
            Color.clear.frame(width: Metrics.squareSize, height: Metrics.squareSize)
        }
    }

    private func select(_ target: UsageHeatmapSelection) {
        cancelHoverClearTask()
        snapSelection = target
        selection = target
    }

    private var showsSquares: Bool {
        areSquaresRevealed || !animatesEntrance
    }

    private func entranceAnimation(column: Int, row: Int) -> Animation? {
        guard areSquaresRevealed,
              animatesEntrance else {
            return nil
        }

        return .spring(
            response: Metrics.entranceResponse,
            dampingFraction: Metrics.entranceDampingFraction
        )
        .delay(entranceDelay(column: column, row: row))
    }

    private func revealSquares() async {
        guard animatesEntrance else {
            areSquaresRevealed = true
            return
        }

        await Task.yield()
        guard !Task.isCancelled else {
            return
        }

        entranceStartedAt = ProcessInfo.processInfo.systemUptime
        areSquaresRevealed = true
    }

    private func entranceDelay(column: Int, row: Int) -> TimeInterval {
        TimeInterval(column + row) * Metrics.entranceStagger
    }

    private func isSquareInteractive(column: Int, row: Int) -> Bool {
        guard showsSquares else {
            return false
        }

        guard animatesEntrance, let entranceStartedAt else {
            return true
        }

        let elapsed = ProcessInfo.processInfo.systemUptime - entranceStartedAt
        let interactiveAt = entranceDelay(column: column, row: row) + Metrics.entranceResponse
        return elapsed >= interactiveAt
    }

    private func localDayText(_ dayKey: String) -> String {
        guard let date = CodexDateFormat.dayDate(from: dayKey) else {
            return dayKey
        }
        return CodexDateFormat.localDayDisplayString(from: date)
    }

    private func updatePointerLocation(_ point: CGPoint) {
        guard let target = snappedSelection(at: point) else {
            scheduleDeactivate()
            return
        }

        cancelHoverClearTask()

        if !matches(snapSelection, target) {
            withAnimation(.snappy(duration: Metrics.snapAnimationDuration)) {
                snapSelection = target
            }
        }

        if !matches(selection, target) {
            activate(target)
        }
    }

    private func snappedSelection(at point: CGPoint) -> UsageHeatmapSelection? {
        // 以格子中心为准吸附, 指针离中心过远时视为离开格子
        let column = Int(((point.x - Metrics.squareSize / 2) / Metrics.squarePitch).rounded())
        let row = Int(((point.y - Metrics.squareSize / 2) / Metrics.squarePitch).rounded())

        guard (0 ..< Metrics.columnCount).contains(column),
              (0 ..< Metrics.rowCount).contains(row),
              isSquareInteractive(column: column, row: row) else {
            return nil
        }

        let center = CGPoint(
            x: CGFloat(column) * Metrics.squarePitch + Metrics.squareSize / 2,
            y: CGFloat(row) * Metrics.squarePitch + Metrics.squareSize / 2
        )
        guard abs(point.x - center.x) <= Metrics.snapHalfExtent,
              abs(point.y - center.y) <= Metrics.snapHalfExtent else {
            return nil
        }

        return UsageHeatmapSelection.at(column: column, row: row, in: days, mode: mode)
    }

    private func activate(_ target: UsageHeatmapSelection) {
        withAnimation(.easeInOut(duration: Metrics.hoverFadeDuration)) {
            selection = target
        }
    }

    private func scheduleDeactivate() {
        cancelHoverClearTask()
        hoverClearTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(Metrics.hoverExitGraceMilliseconds))
            guard !Task.isCancelled else {
                return
            }

            withAnimation(.easeInOut(duration: Metrics.hoverFadeDuration)) {
                snapSelection = nil
                selection = nil
            }
        }
    }

    private func cancelHoverClearTask() {
        hoverClearTask?.cancel()
        hoverClearTask = nil
    }

    private func matches(_ lhs: UsageHeatmapSelection?, _ rhs: UsageHeatmapSelection) -> Bool {
        lhs == rhs
    }
}

extension UsageHeatmap {
    enum Metrics {
        static let columnCount = 30
        static let rowCount = CodexWeekGrid.rowCount
        static let squareSize: CGFloat = 12
        static let squareSpacing: CGFloat = 3
        static let squarePitch = squareSize + squareSpacing
        static let height: CGFloat = 120
        static let snapAnimationDuration: TimeInterval = 0.12
        static let hoverFadeDuration: TimeInterval = 0.15
        static let hoverExitGraceMilliseconds: UInt64 = 160
        static let snapHalfExtent: CGFloat = squareSize / 2 + squareSpacing
        static let entranceScale: CGFloat = 0.35
        static let entranceStagger: TimeInterval = 0.015
        static let entranceResponse: TimeInterval = 0.25
        static let entranceDampingFraction = 0.60

        static var totalWidth: CGFloat {
            CGFloat(columnCount) * squareSize + CGFloat(columnCount - 1) * squareSpacing
        }

        static var gridHeight: CGFloat {
            CGFloat(rowCount) * squareSize + CGFloat(rowCount - 1) * squareSpacing
        }

        static func preferredDetailSide(for column: Int) -> UsageHeatmapDetailSide {
            column < columnCount / 2 ? .left : .right
        }
    }
}

// MARK: - 单元格

/// 单个热力图方块, 蓝色透明度表示当天 token 强度, 中性色表示 token 数据不可用
private struct UsageHeatmapSquare: View {
    let tokenState: UsageHeatmapTokenState
    let percent: Double
    let isHovered: Bool
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(fillColor)
            .overlay {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .stroke(borderColor, lineWidth: isHovered ? 1.2 : 0.7)
            }
            .shadow(color: shadowColor, radius: isHovered ? 5 : 0, y: isHovered ? 2 : 0)
            .scaleEffect(isHovered ? 1.08 : 1)
            .frame(width: UsageHeatmap.Metrics.squareSize, height: UsageHeatmap.Metrics.squareSize)
            .contentShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            .animation(.snappy(duration: 0.14), value: isHovered)
    }

    private var clampedPercent: Double {
        min(max(percent, 0), 1)
    }

    private var fillColor: Color {
        guard tokenState.count != nil else {
            return Color.secondary.opacity(isHovered ? 0.12 : 0.05)
        }
        guard (tokenState.count ?? 0) > 0 else {
            return tint.opacity(isHovered ? 0.16 : 0.08)
        }

        let intensity = pow(clampedPercent, 0.62)
        let opacity = 0.18 + intensity * 0.68
        return tint.opacity(isHovered ? min(opacity + 0.10, 1.0) : opacity)
    }

    private var borderColor: Color {
        guard tokenState.count != nil else {
            return Color.secondary.opacity(isHovered ? 0.42 : 0.12)
        }
        if isHovered {
            return tint.opacity(0.78)
        }

        return tint.opacity((tokenState.count ?? 0) > 0 ? 0.18 : 0.10)
    }

    private var shadowColor: Color {
        tokenState.count == nil ? .clear : tint.opacity(0.22)
    }

    private var tint: Color {
        colorScheme == .dark ? CodexDarkPalette.heatmap : .blue
    }
}

struct UsageHeatmapDayDetailView: View {
    let context: UsageHeatmapHoverContext
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let panelSize = Self.panelSize(showsWorkflow: context.showsExtendedDetails, isWeekly: context.period.isWeekly)

        detailContent
            .padding(.horizontal, Metrics.horizontalPadding)
            .padding(.vertical, Metrics.verticalPadding)
            .frame(
                width: panelSize.width,
                height: panelSize.height,
                alignment: .topLeading
            )
            .sidePanelChrome(cornerRadius: Metrics.cornerRadius)
            .animation(Metrics.statusAnimation, value: context)
    }

    static var panelCornerRadius: CGFloat {
        Metrics.cornerRadius
    }

    static func panelSize(showsWorkflow: Bool, isWeekly: Bool = false) -> CGSize {
        CGSize(
            width: showsWorkflow ? 380 : isWeekly ? 280 : Metrics.panelWidth,
            height: showsWorkflow ? Metrics.workflowPanelHeight : Metrics.tokenPanelHeight
        )
    }

    @ViewBuilder
    private var detailContent: some View {
        if context.showsWorkflow {
            workflowContent
        } else if let day = context.recordedDay {
            recordedContent(day)
        } else {
            tokenOnlyContent
        }
    }

    private func recordedContent(_ day: UsageDay) -> some View {
        VStack(alignment: .leading, spacing: Metrics.sectionSpacing) {
            header
            LiquidGlassDivider().opacity(0.72)
            tokenIntensityStrip
            detailColumns(activity: recordedRows(day), usage: day)
        }
        .help(context.period.isWeekly
            ? String(localized: "usage.heatmap.recorded-week-help", defaultValue: "按 UTC 日期汇总已采集日志, 会话日数为每日会话数之和, 同一会话跨日会计多次")
            : "设备日志按 UTC 统计; 输入不含已单列的缓存, 缺失的权限和推理用量显示未知")
    }

    private func detailColumns(activity: [RecordedMetricRow], usage: UsageDay?) -> some View {
        HStack(alignment: .top, spacing: 12) {
            metricColumn(context.showsWorkflow ? "本机 Hook" : "任务统计", rows: activity)
            Rectangle().fill(Color.primary.opacity(0.08)).frame(width: 1)
            metricColumn("设备日志 Token", rows: tokenRows(usage))
        }
        .frame(height: 162)
    }

    private func metricColumn(_ title: String, rows: [RecordedMetricRow]) -> some View {
        VStack(alignment: .leading, spacing: Metrics.metricSpacing) {
            Text(title).font(.caption2.weight(.semibold)).foregroundStyle(Color.codexSecondaryLabel)
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                metricRowLayout {
                    metricDot(tint: row.tint)
                    Text(row.label).foregroundStyle(.secondary).fixedSize()
                    Spacer(minLength: 4)
                    Text(row.value).foregroundStyle(Color.codexLabel).monospacedDigit()
                        .lineLimit(1).minimumScaleFactor(0.65)
                        .contentTransition(.numericText())
                }
                .help("\(row.label): \(row.value)")
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity)
    }

    private func tokenRows(_ day: UsageDay?) -> [RecordedMetricRow] {
        let metrics = day?.metrics
        func tokens(_ value: Int64?) -> String {
            value.map { TokenCountFormatter.parts(from: Int(clamping: $0)).text } ?? "—"
        }
        let input = metrics.map { $0.tokens - $0.output }
        let cacheRate = input.map { total in
            total > 0 ? Double(metrics?.cacheRead ?? 0) / Double(total) : 0
        }
        return [
            RecordedMetricRow(label: "合计", value: tokens(day?.tokens), tint: .blue),
            RecordedMetricRow(label: "输入", value: tokens(metrics?.input), tint: .indigo),
            RecordedMetricRow(label: "输出", value: tokens(metrics?.output), tint: .orange),
            RecordedMetricRow(label: "缓存读取", value: tokens(metrics?.cacheRead), tint: .green),
            RecordedMetricRow(label: "缓存写入", value: tokens(metrics?.cacheWrite), tint: .purple),
            RecordedMetricRow(label: "缓存占比", value: cacheRate.map { $0.formatted(.percent.precision(.fractionLength(0 ... 1))) } ?? "—", tint: .teal)
        ]
    }

    private struct RecordedMetricRow {
        let label: String
        let value: String
        let tint: Color
    }

    private func recordedRows(_ day: UsageDay) -> [RecordedMetricRow] {
        let metrics = day.metrics
        func count(_ value: Int64?) -> String {
            value?.formatted() ?? "—"
        }
        return [
            RecordedMetricRow(label: "主要模型", value: day.topModel ?? "—", tint: .cyan),
            RecordedMetricRow(label: sessionCountLabel, value: count(metrics?.sessions), tint: .green),
            RecordedMetricRow(label: "对话轮次", value: count(metrics?.turns), tint: .teal),
            RecordedMetricRow(label: "工具调用", value: count(metrics?.tools), tint: .orange),
            RecordedMetricRow(label: "子智能体", value: count(metrics?.subagents), tint: .indigo),
            RecordedMetricRow(label: "上下文压缩", value: count(metrics?.compactions), tint: .purple),
            RecordedMetricRow(label: "权限请求", value: count((metrics?.permissions ?? 0) > 0 ? metrics?.permissions : nil), tint: .red),
            RecordedMetricRow(label: "任务中断", value: count(metrics?.interruptions), tint: .orange)
        ]
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 0) {
            dateText
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .liquidGlassCapsule(tint: .accentColor)

            Spacer(minLength: 8)

            if context.recordedDay != nil, !context.showsWorkflow {
                Text("日志").font(.caption2).foregroundStyle(.tertiary)
            }

            tokenText
        }
    }

    private var workflowContent: some View {
        VStack(alignment: .leading, spacing: Metrics.sectionSpacing) {
            header
            LiquidGlassDivider().opacity(0.72)
            tokenIntensityStrip
            detailColumns(
                activity: [RecordedMetricRow(label: "主要模型", value: context.day.workflow.mostUsedModel ?? "—", tint: .cyan)]
                    + workflowMetricRows.map { RecordedMetricRow(label: $0.label, value: $0.value.formatted(), tint: $0.tint) }
                    + [RecordedMetricRow(label: "任务中断", value: context.day.workflow.interruptCount?.formatted() ?? "—", tint: .orange)],
                usage: context.recordedDay
            )
        }
        .help(context.period.isWeekly
            ? String(localized: "usage.heatmap.workflow-week-help", defaultValue: "顶部为官方账号用量, 本机 Hook 和设备日志分别汇总; 会话日数为每日会话数之和")
            : "顶部为官方账号用量; 左侧为本机 Hook, 右侧为已采集设备日志, 两者不相加")
    }

    private var tokenOnlyContent: some View {
        VStack(alignment: .leading, spacing: Metrics.sectionSpacing) {
            header

            LiquidGlassDivider()
                .opacity(0.62)

            tokenOnlyFooter
        }
    }

    private var tokenOnlyFooter: some View {
        metricRowLayout {
            tokenIntensityDot
            Text("usage.heatmap.intensity")
                .foregroundStyle(.secondary)

            Spacer(minLength: 8)

            tokenIntensityStrip
                .frame(width: Metrics.tokenIntensityStripWidth)
        }
    }

    private var tokenIntensityDot: some View {
        metricDot(tint: .blue, darkOpacity: 0.88, lightOpacity: 0.76)
    }

    private func metricRowLayout(@ViewBuilder content: () -> some View) -> some View {
        HStack(spacing: Metrics.metricRowSpacing, content: content)
            .font(.system(size: Metrics.workflowFontSize))
            .frame(height: Metrics.metricRowHeight)
    }

    private func metricDot(tint: Color, darkOpacity: Double = 0.86, lightOpacity: Double = 0.72) -> some View {
        Circle()
            .fill(tint.opacity(colorScheme == .dark ? darkOpacity : lightOpacity))
            .frame(width: Metrics.metricDotSize, height: Metrics.metricDotSize)
    }

    private var tokenIntensityStrip: some View {
        HStack(spacing: Metrics.tokenIntensitySegmentSpacing) {
            ForEach(0 ..< Metrics.tokenIntensitySegmentCount, id: \.self) { index in
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(tokenIntensityFill(for: index))
                    .frame(maxWidth: .infinity)
            }
        }
        .frame(height: Metrics.tokenIntensityStripHeight)
    }

    private var workflowMetricRows: [WorkflowMetricRow] {
        [
            WorkflowMetricRow(
                label: sessionCountLabel,
                value: context.day.workflow.sessionCount,
                tint: .green
            ),
            WorkflowMetricRow(
                label: String(localized: "workflow.metric.turns"),
                value: context.day.workflow.turnCount,
                tint: .teal
            ),
            WorkflowMetricRow(
                label: String(localized: "workflow.metric.subagents"),
                value: context.day.workflow.subagentCount,
                tint: .indigo
            ),
            WorkflowMetricRow(
                label: String(localized: "workflow.metric.tool-calls"),
                value: context.day.workflow.toolCallCount,
                tint: .orange
            ),
            WorkflowMetricRow(
                label: String(localized: "workflow.metric.approvals"),
                value: context.day.workflow.permissionRequestCount,
                tint: .red
            ),
            WorkflowMetricRow(
                label: String(localized: "workflow.metric.compactions"),
                value: context.day.workflow.contextCompactionCount,
                tint: .purple
            )
        ]
    }

    private var sessionCountLabel: String {
        context.period.isWeekly
            ? String(localized: "usage.heatmap.session-days", defaultValue: "会话日数")
            : String(localized: "workflow.metric.sessions")
    }

    private var dateText: some View {
        Group {
            if context.period.isWeekly {
                Text(verbatim: context.day.startDate + " ~ " + context.period.endDate)
                    .font(dateFont)
            } else {
                AnimatedDateText(startDate: context.day.startDate, font: dateFont)
            }
        }
        .foregroundStyle(Color.codexSecondaryLabel)
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
        .layoutPriority(1)
    }

    private var tokenText: some View {
        HeatmapTokenText(
            tokenState: context.day.tokenState,
            font: tokenFont,
            numericWidth: Metrics.tokenMinimumWidth,
            unitWidth: Metrics.tokenUnitWidth
        )
    }

    private var dateFont: Font {
        .caption2.monospacedDigit()
    }

    private var tokenFont: Font {
        .system(size: 14).monospacedDigit().weight(.semibold)
    }

    private var tokenIntensityLevel: Int {
        guard context.day.tokensForHeatmap > 0 else {
            return 0
        }

        let percent = tokenIntensityPercent
        return min(
            Metrics.tokenIntensitySegmentCount,
            max(1, Int(ceil(percent * Double(Metrics.tokenIntensitySegmentCount))))
        )
    }

    private var tokenIntensityPercent: Double {
        guard context.peakTokens > 0 else {
            return 0
        }

        return min(max(Double(context.day.tokensForHeatmap) / Double(context.peakTokens), 0), 1)
    }

    private func tokenIntensityFill(for index: Int) -> Color {
        guard context.day.tokenCount != nil else {
            return Color.secondary.opacity(colorScheme == .dark ? 0.18 : 0.12)
        }

        guard index < tokenIntensityLevel else {
            return Color.blue.opacity(colorScheme == .dark ? 0.14 : 0.10)
        }

        let position = Double(index) / Double(Metrics.tokenIntensitySegmentCount - 1)
        let opacity = colorScheme == .dark ? 0.42 + position * 0.40 : 0.34 + position * 0.36
        return Color.blue.opacity(min(opacity, 0.88))
    }

    private struct WorkflowMetricRow: Identifiable {
        let label: String
        let value: Int
        let tint: Color

        var id: String {
            label
        }
    }

    private enum Metrics {
        static let panelWidth: CGFloat = 212
        static let workflowPanelHeight: CGFloat = 232
        static let tokenPanelHeight: CGFloat = 84
        static let sectionSpacing: CGFloat = 8
        static let horizontalPadding: CGFloat = 12
        static let verticalPadding: CGFloat = 10
        static let cornerRadius: CGFloat = 12
        static let tokenMinimumWidth: CGFloat = 38
        static let tokenUnitWidth: CGFloat = 14
        static let metricSpacing: CGFloat = 5
        static let metricRowSpacing: CGFloat = 6
        static let metricDotSize: CGFloat = 5
        static let metricRowHeight: CGFloat = 14
        static let metricLabelWidth: CGFloat = 72
        static let metricValueMinimumScale: CGFloat = 0.60
        static let workflowFontSize: CGFloat = 11
        static let tokenIntensitySegmentCount = 10
        static let tokenIntensitySegmentSpacing: CGFloat = 3
        static let tokenIntensityStripWidth: CGFloat = 74
        static let tokenIntensityStripHeight: CGFloat = 5
        static let statusAnimation = Animation.codexStatus
    }
}

/// token 详情在数字和占位状态之间切换时只做淡入淡出, 数字之间仍保留滚动过渡
private struct HeatmapTokenText: View {
    let tokenState: UsageHeatmapTokenState
    let font: Font
    let numericWidth: CGFloat
    let unitWidth: CGFloat

    @State private var displayedTokenState: UsageHeatmapTokenState
    @State private var isVisible = true

    init(
        tokenState: UsageHeatmapTokenState,
        font: Font,
        numericWidth: CGFloat,
        unitWidth: CGFloat
    ) {
        self.tokenState = tokenState
        self.font = font
        self.numericWidth = numericWidth
        self.unitWidth = unitWidth
        _displayedTokenState = State(initialValue: tokenState)
    }

    var body: some View {
        content
            .opacity(isVisible ? 1 : 0)
            .frame(minWidth: width, alignment: .trailing)
            .task(id: tokenState) {
                await updateDisplayedTokenState(tokenState)
            }
    }

    @ViewBuilder
    private var content: some View {
        switch displayedTokenState {
        case let .available(tokenCount):
            TokenCountText(
                tokens: tokenCount,
                font: font,
                reservedNumericWidth: numericWidth,
                reservedUnitWidth: unitWidth
            )
            .foregroundStyle(Color.codexLabel)

        case .pending:
            Image(systemName: "questionmark")
                .font(font)
                .foregroundStyle(Color.codexLabel)

        case .unavailable:
            Text(verbatim: "--")
                .font(font)
                .foregroundStyle(Color.codexLabel)
        }
    }

    private func updateDisplayedTokenState(_ newTokenState: UsageHeatmapTokenState) async {
        guard displayedTokenState != newTokenState || !isVisible else {
            return
        }

        if displayedTokenState.count != nil, newTokenState.count != nil {
            updateTokenStateWithoutFade(newTokenState)
        } else if displayedTokenState == newTokenState {
            withAnimation(Metrics.fadeAnimation) {
                isVisible = true
            }
        } else {
            await fadeToTokenState(newTokenState)
        }
    }

    private func updateTokenStateWithoutFade(_ newTokenState: UsageHeatmapTokenState) {
        withAnimation(Metrics.numericAnimation) {
            displayedTokenState = newTokenState
            isVisible = true
        }
    }

    private func fadeToTokenState(_ newTokenState: UsageHeatmapTokenState) async {
        withAnimation(Metrics.fadeAnimation) {
            isVisible = false
        }

        try? await Task.sleep(for: .milliseconds(Metrics.fadeDelayMilliseconds))
        guard !Task.isCancelled else {
            return
        }

        displayedTokenState = newTokenState
        withAnimation(Metrics.fadeAnimation) {
            isVisible = true
        }
    }

    private var width: CGFloat {
        numericWidth + unitWidth
    }

    private enum Metrics {
        static let fadeAnimation = Animation.easeInOut(duration: 0.12)
        static let fadeDelayMilliseconds: UInt64 = 120
        static let numericAnimation = Animation.codexStatus
    }
}

/// 日期拆成三段以固定 yyyy-MM-dd 格式并保留自然的数字滚动过渡
private struct AnimatedDateText: View {
    let startDate: String
    let font: Font

    var body: some View {
        if let components {
            HStack(spacing: 0) {
                Text(verbatim: components.year)
                Text(verbatim: "-")
                Text(verbatim: components.month)
                Text(verbatim: "-")
                Text(verbatim: components.day)
            }
            .font(font)
            .contentTransition(.numericText(value: dateValue(components)))
        } else {
            Text(verbatim: startDate)
                .font(font)
                .contentTransition(.numericText())
        }
    }

    private func dateValue(_ components: DateTextComponents) -> Double {
        guard let year = Int(components.year),
              let month = Int(components.month),
              let day = Int(components.day) else {
            return 0
        }
        return Double(year * 10000 + month * 100 + day)
    }

    private var components: DateTextComponents? {
        let parts = startDate.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3,
              parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) else {
            return nil
        }

        return DateTextComponents(year: parts[0], month: parts[1], day: parts[2])
    }

    private struct DateTextComponents {
        let year: String
        let month: String
        let day: String
    }
}
