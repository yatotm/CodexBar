import Charts
import SwiftUI

struct UsageCenterView: View {
    @ObservedObject var viewModel: UsageCenterViewModel
    @State private var editingSource: UsageSource?
    @State private var deletingSource: UsageSource?
    @State private var showAddProbeSheet = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 0) {
            sidebarPane
                .frame(width: 234)
            Rectangle()
                .fill(ControlCenterPalette.cardBorder(colorScheme))
                .frame(width: 1)
            VStack(spacing: 0) {
                mainHeaderBar
                Rectangle()
                    .fill(ControlCenterPalette.subtleBorder(colorScheme))
                    .frame(height: 1)
                if viewModel.activeSection == .deployment {
                    ControlCenterDeploymentView(
                        viewModel: viewModel,
                        editingSource: $editingSource,
                        deletingSource: $deletingSource,
                        showAddProbeSheet: $showAddProbeSheet
                    )
                } else {
                    usageCanvas
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(ControlCenterPalette.canvasBackground(colorScheme))
        }
        .ignoresSafeArea(.container, edges: .top)
        .sheet(item: $editingSource) { source in
            UsageSourceEditor(viewModel: viewModel, source: source)
        }
        .alert("移除监控节点?", isPresented: Binding(
            get: { deletingSource != nil },
            set: {
                if !$0 {
                    deletingSource = nil
                }
            }
        )) {
            Button("取消", role: .cancel) { deletingSource = nil }
            Button("移除", role: .destructive) {
                if let source = deletingSource {
                    Task { await viewModel.remove(source) }
                }
                deletingSource = nil
            }
        } message: {
            Text("移除此节点在本机的统计缓存和关联密钥")
        }
    }

    // MARK: - 侧边栏导航

    private var sidebarPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 18) {
                sidebarSectionTitle("工作区")
                VStack(spacing: 3) {
                    SidebarNavRow(
                        title: "用量总览",
                        subtitle: "全设备汇总与估值",
                        symbol: "chart.bar.xaxis",
                        tint: .accentColor,
                        isSelected: viewModel.activeSection == .usage && viewModel.filter.sourceID.isEmpty,
                        badge: nil
                    ) {
                        viewModel.filter.sourceID = ""
                        viewModel.activeSection = .usage
                    }
                    SidebarNavRow(
                        title: "节点与部署",
                        subtitle: viewModel.topologyMode.title,
                        symbol: "antenna.radiowaves.left.and.right",
                        tint: .indigo,
                        isSelected: viewModel.activeSection == .deployment,
                        badge: onlineNodesBadge
                    ) {
                        viewModel.activeSection = .deployment
                    }
                }
                sidebarSectionTitle("监控设备")
            }
            .padding(.top, 44)
            .padding(.horizontal, 12)
            .padding(.bottom, 8)

            ScrollView {
                VStack(spacing: 3) {
                    ForEach(viewModel.effectiveSources) { source in
                        SidebarDeviceRow(
                            source: source,
                            status: viewModel.statuses[source.id],
                            isSelected: viewModel.activeSection == .usage && viewModel.filter.sourceID == source.id,
                            canEdit: !viewModel.isRefreshing,
                            onSelect: {
                                viewModel.filter.sourceID = source.id
                                viewModel.activeSection = .usage
                            },
                            onConfigure: {
                                if source.transport == .probe {
                                    viewModel.activeSection = .deployment
                                } else {
                                    editingSource = source
                                }
                            }
                        )
                        .contextMenu {
                            if source.transport == .probe {
                                Button("前往节点与部署管理") { viewModel.activeSection = .deployment }
                            } else {
                                Button("目录与高级设置") { editingSource = source }
                                    .disabled(viewModel.isRefreshing)
                            }
                            if source.id != "local" {
                                Divider()
                                Button("移除节点", role: .destructive) { deletingSource = source }
                                    .disabled(viewModel.isRefreshing)
                            }
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
            }
            Spacer(minLength: 0)
            sidebarFooter
        }
        .background(ControlCenterVibrancySidebar())
    }

    private func sidebarSectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
    }

    private var onlineNodesBadge: String {
        let enabled = viewModel.effectiveSources.filter(\.isEnabled)
        let online = enabled.filter { src in
            if src.transport == .local {
                return true
            }
            if src.transport == .probe {
                return src.isOnline
            }
            return viewModel.statuses[src.id]?.error == nil && viewModel.statuses[src.id]?.lastSuccess != nil
        }.count
        return "\(online)/\(enabled.count)"
    }

    private var sidebarFooter: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(ControlCenterPalette.subtleBorder(colorScheme))
                .frame(height: 1)
            HStack(spacing: 8) {
                Circle()
                    .fill(hubIndicatorColor)
                    .frame(width: 7, height: 7)
                VStack(alignment: .leading, spacing: 1) {
                    Text(viewModel.topologyMode.title)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(viewModel.hubStatusText)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                Menu {
                    Toggle("每 5 分钟自动刷新", isOn: $viewModel.automaticRefresh)
                    Divider()
                    Button("切换部署架构…") { viewModel.activeSection = .deployment }
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 24)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 24)
                .help("同步与刷新设置")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
        }
    }

    private var hubIndicatorColor: Color {
        if viewModel.topologyMode == .localOnly {
            return ControlCenterPalette.codex
        }
        guard let healthy = viewModel.hubHealthy else { return .secondary }
        return healthy ? .green : .orange
    }

    // MARK: - 顶部统一标题与操作栏

    private var mainHeaderBar: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(headerTitle)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.primary)
                Text(headerSubtitle)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if viewModel.activeSection == .usage {
                ControlCenterPillPicker(options: authOptions, selection: $viewModel.filter.authentication)
            } else if viewModel.topologyMode != .localOnly {
                Button {
                    showAddProbeSheet = true
                } label: {
                    Label("添加探针节点", systemImage: "plus")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
            refreshActionControl
        }
        .padding(.horizontal, 22)
        .frame(height: 56)
    }

    private var headerTitle: String {
        if viewModel.activeSection == .deployment {
            return "节点与部署架构"
        }
        if viewModel.filter.sourceID.isEmpty {
            return "全部节点 · 用量统计"
        }
        return (viewModel.effectiveSources.first { $0.id == viewModel.filter.sourceID }?.name ?? "监控设备") + " · 用量统计"
    }

    private var headerSubtitle: String {
        if viewModel.activeSection == .deployment {
            return "零 Hooks 单向签名探针 · 支持按机器独立配置监控渠道"
        }
        return "UTC 自然日对齐 · 跨设备记录自动去重 · 订阅价值按当前登录账号独立核算"
    }

    @ViewBuilder
    private var refreshActionControl: some View {
        if viewModel.isRefreshing {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Button("停止") { viewModel.cancelRefresh() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        } else {
            Button {
                viewModel.refresh(manual: true)
            } label: {
                Label("刷新", systemImage: "arrow.clockwise")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .keyboardShortcut("r", modifiers: .command)
            .help("立即同步最新数据 (⌘R)")
        }
    }

    // MARK: - 用量统计主画布

    private var usageCanvas: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                filterToolbar
                if let error = viewModel.error {
                    errorBanner(error)
                }
                if viewModel.dashboardFilter == viewModel.filter {
                    bentoSummarySection
                    UsageDailyChart(days: viewModel.dashboard.days, accentColor: activeChartAccent)
                        .padding(16)
                        .usageCenterCard()
                    UsageBreakdownView(groups: viewModel.dashboard.groups, grouping: $viewModel.filter.grouping)
                        .padding(16)
                        .usageCenterCard()
                    valuationSections
                    quotaSectionCard
                    recentActivityCard
                } else if viewModel.error == nil {
                    ProgressView("正在汇总统计数据…")
                        .frame(maxWidth: .infinity, minHeight: 220)
                }
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 18)
        }
    }

    private var activeChartAccent: Color {
        ControlCenterPalette.providerAccent(viewModel.filter.provider)
    }

    private var filterToolbar: some View {
        HStack(spacing: 12) {
            if providerOptions.count > 1 {
                ControlCenterPillPicker(options: providerOptions, selection: $viewModel.filter.provider)
            }
            Spacer(minLength: 8)
            ControlCenterPillPicker(options: dayOptions, selection: $viewModel.filter.days)
        }
    }

    private var providerOptions: [ControlCenterPillOption<String>] {
        let providers = viewModel.activeProviders
        let scopes: [UsageMenuScope] = providers.count <= 1 ? (providers.isEmpty ? [.codex] : providers) : ([.all] + providers)
        return scopes.map { scope in
            let dot: Color? = switch scope {
            case .all: nil
            case .codex: ControlCenterPalette.codex
            case .claude: ControlCenterPalette.claude
            case .gemini: ControlCenterPalette.gemini
            }
            return ControlCenterPillOption(value: scope.rawValue, title: scope.title, dotColor: dot)
        }
    }

    private var authOptions: [ControlCenterPillOption<String>] {
        [ControlCenterPillOption(value: "", title: "全部凭据")]
            + UsageAuthentication.allCases.map { ControlCenterPillOption(value: $0.rawValue, title: $0.title) }
    }

    private var dayOptions: [ControlCenterPillOption<Int>] {
        [
            ControlCenterPillOption(value: 1, title: "今天"),
            ControlCenterPillOption(value: 7, title: "7 天"),
            ControlCenterPillOption(value: 30, title: "30 天"),
            ControlCenterPillOption(value: 90, title: "90 天"),
            ControlCenterPillOption(value: 210, title: "210 天")
        ]
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(.primary)
            Spacer()
        }
        .padding(12)
        .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.orange.opacity(0.28), lineWidth: 0.8)
        }
    }

    private var bentoSummarySection: some View {
        let metrics = viewModel.dashboard.totals
        let cachedTotal = metrics.cacheRead + metrics.cacheWrite
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                ControlCenterBentoMetricCard(
                    title: "已采集 Token",
                    value: metrics.tokens.formatted(.number.notation(.compactName)),
                    detail: "输出 \(metrics.output.formatted(.number.notation(.compactName))) · 缓存 \(cachedTotal.formatted(.number.notation(.compactName)))",
                    symbol: "sparkles.rectangle.stack.fill",
                    tint: activeChartAccent
                )
                ControlCenterBentoMetricCard(
                    title: "活跃会话",
                    value: metrics.sessions.formatted(.number.notation(.compactName)),
                    detail: "子智能体 \(metrics.subagents.formatted(.number.notation(.compactName))) 次",
                    symbol: "bubble.left.and.bubble.right.fill",
                    tint: Color(hex: 0x10B981)
                )
                ControlCenterBentoMetricCard(
                    title: "对话总轮次",
                    value: metrics.turns.formatted(.number.notation(.compactName)),
                    detail: viewModel.dashboard.longestTurnMs.map { "最长单轮 \($0 / 1000)s" } ?? "自动剔除重复事件",
                    symbol: "arrow.triangle.2.circlepath.circle.fill",
                    tint: Color(hex: 0x8B5CF6)
                )
                ControlCenterBentoMetricCard(
                    title: "工具调用",
                    value: metrics.tools.formatted(.number.notation(.compactName)),
                    detail: "上下文压缩 \(metrics.compactions.formatted(.number.notation(.compactName))) 次",
                    symbol: "wrench.and.screwdriver.fill",
                    tint: Color(hex: 0xF59E0B)
                )
            }
            secondaryMetricsDrawer(metrics)
        }
    }

    private func secondaryMetricsDrawer(_ metrics: UsageMetrics) -> some View {
        UsageDisclosure(title: "展开详细 Token 构成与运行细分指标") {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: 4), spacing: 14) {
                secondaryMetricItem("输入 Token", metrics.input)
                secondaryMetricItem("输出 Token", metrics.output)
                secondaryMetricItem("缓存读取", metrics.cacheRead)
                secondaryMetricItem("缓存写入", metrics.cacheWrite)
                secondaryMetricItem("子智能体启动", metrics.subagents)
                secondaryMetricItem("上下文压缩", metrics.compactions)
                secondaryMetricItem("权限审批请求", metrics.permissions > 0 ? metrics.permissions : nil)
                secondaryMetricItem("最长单轮秒数", viewModel.dashboard.longestTurnMs.map { $0 / 1000 })
            }
            .padding(.top, 10)
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .usageCenterCard(cornerRadius: 10)
    }

    private func secondaryMetricItem(_ title: String, _ value: Int64?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 11)).foregroundStyle(.secondary)
            Text(value?.formatted() ?? "未记录")
                .font(.system(size: 13.5, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.primary)
        }
    }

    @ViewBuilder
    private var valuationSections: some View {
        if viewModel.filter.authentication != "api" {
            let selected = viewModel.filter.provider
            if selected.isEmpty || selected == "codex", viewModel.isProviderEnabledAnywhere(.codex) {
                UsageAnalyticsView(model: viewModel.analytics)
            }
            if selected.isEmpty || selected == "claude", viewModel.isProviderEnabledAnywhere(.claude) {
                ProviderValuationView(
                    provider: "claude",
                    title: "Claude 订阅区间价值",
                    subtitle: "跨节点会话去重 · Claude 7d 额度锚定 · API 标准单价外推",
                    pricingURL: URL(string: viewModel.geminiPriceBook.claudeApiSource ?? "https://docs.anthropic.com/en/docs/about-claude/pricing")!,
                    periods: viewModel.claudePeriods,
                    priceBook: viewModel.geminiPriceBook,
                    hasOfflineNodes: viewModel.hasOfflineClaudeNodes,
                    isRefreshing: viewModel.isRefreshing,
                    onRefresh: { viewModel.refresh() }
                )
            }
            if selected.isEmpty || selected == "gemini", viewModel.isProviderEnabledAnywhere(.gemini) {
                ProviderValuationView(
                    provider: "gemini",
                    title: "Gemini 订阅区间价值",
                    subtitle: "当前登录 Google 账号隔离 · Gemini 7d 额度锚定 · API 标准单价外推",
                    pricingURL: URL(string: viewModel.geminiPriceBook.geminiApiSource ?? "https://ai.google.dev/gemini-api/docs/pricing")!,
                    periods: viewModel.geminiPeriods,
                    priceBook: viewModel.geminiPriceBook,
                    hasOfflineNodes: viewModel.hasOfflineGeminiNodes,
                    isRefreshing: viewModel.isRefreshing,
                    onRefresh: { viewModel.refresh() }
                )
            }
        }
    }

    // MARK: - 额度快照与最近任务

    private var quotaSectionCard: some View {
        let entries = visibleQuotas
        return VStack(alignment: .leading, spacing: 12) {
            ControlCenterSectionHeader(
                title: "实时额度快照",
                subtitle: "优先采用最新带重置时间的记录, 跨机器同账号额度不相加",
                symbol: "gauge.with.dots.needle.33percent",
                tint: .teal
            )
            if entries.isEmpty {
                Text("当前筛选范围内暂无额度观测记录")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 6)
            } else {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                    ForEach(entries) { entry in
                        let isPrimary = entries.first(where: { $0.quota.provider == entry.quota.provider })?.id == entry.id
                        quotaTile(entry: entry, isPrimary: isPrimary)
                    }
                }
            }
        }
        .padding(16)
        .usageCenterCard()
    }

    private func quotaTile(entry: QuotaEntry, isPrimary: Bool) -> some View {
        let accent = ControlCenterPalette.providerAccent(entry.quota.provider)
        return VStack(alignment: .leading, spacing: 9) {
            HStack {
                HStack(spacing: 6) {
                    Circle().fill(accent).frame(width: 7, height: 7)
                    Text(groupName(entry.quota.provider))
                        .font(.system(size: 12.5, weight: .semibold))
                    Text("· " + entry.source.name)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if isPrimary {
                    ControlCenterStatusBadge(title: "当前采用", color: accent)
                }
            }
            ForEach(entry.quota.windows, id: \.name) { win in
                quotaWindowRow(win, accent: accent)
            }
        }
        .padding(12)
        .opacity(isPrimary ? 1.0 : 0.65)
        .usageCenterInset(cornerRadius: 10)
        .help("观测时间: " + Date(timeIntervalSince1970: entry.quota.observedAt).formatted())
    }

    private func quotaWindowRow(_ window: UsageQuotaObservation.Window, accent: Color) -> some View {
        let now = Date().timeIntervalSince1970
        let expired = window.resetsAt.map { $0 <= now } ?? false
        let remaining = max(0, min(100, Int((100.0 - window.usedPercent).rounded())))
        let resetLabel = window.resetsAt.map {
            Date(timeIntervalSince1970: $0).formatted(.dateTime.month(.twoDigits).day(.twoDigits).hour().minute())
        } ?? ""
        return HStack(spacing: 8) {
            Text(window.name.uppercased())
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 26, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.08))
                    if !expired {
                        Capsule()
                            .fill(remaining <= 15 ? Color.red : remaining <= 35 ? Color.orange : accent)
                            .frame(width: geo.size.width * (Double(remaining) / 100.0))
                    }
                }
            }
            .frame(height: 5)
            Text(expired ? "待刷新" : "剩 \(remaining)%")
                .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                .foregroundStyle(expired ? .secondary : .primary)
                .frame(width: 54, alignment: .trailing)
            if !resetLabel.isEmpty {
                Text(resetLabel)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .frame(width: 78, alignment: .trailing)
            }
        }
    }

    private var visibleQuotas: [QuotaEntry] {
        var entries: [QuotaEntry] = []
        for source in viewModel.effectiveSources where source.isEnabled {
            guard viewModel.filter.sourceID.isEmpty || viewModel.filter.sourceID == source.id else { continue }
            for quota in viewModel.statuses[source.id]?.quotas ?? [] {
                guard viewModel.filter.provider.isEmpty || viewModel.filter.provider == quota.provider else { continue }
                if source.includesProvider(quota.provider) {
                    entries.append(QuotaEntry(source: source, quota: quota))
                }
            }
        }
        let now = Date().timeIntervalSince1970
        let newest = Dictionary(grouping: entries, by: { $0.quota.provider }).mapValues {
            $0.max { $1.quota.isPreferred(over: $0.quota, at: now) }?.id
        }
        return entries.sorted { lhs, rhs in
            let lhsLatest = newest[lhs.quota.provider] == lhs.id
            let rhsLatest = newest[rhs.quota.provider] == rhs.id
            if lhsLatest != rhsLatest {
                return lhsLatest
            }
            if lhs.quota.observedAt != rhs.quota.observedAt {
                return lhs.quota.observedAt > rhs.quota.observedAt
            }
            return lhs.id < rhs.id
        }
    }

    private struct QuotaEntry: Identifiable {
        let source: UsageSource
        let quota: UsageQuotaObservation
        var id: String {
            source.id + ":" + quota.provider
        }
    }

    private var recentActivityCard: some View {
        let items = Array(viewModel.dashboard.activities.prefix(10))
        return UsageDisclosure(title: "最近记录的任务动态 (\(items.count))") {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(items) { task in
                    recentActivityRow(task)
                }
                Text("超过 5 分钟没有进展的运行状态显示为待确认; 远程节点与 Claude / Gemini 任务不参与本机 Codex 防睡眠判定")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .padding(.top, 4)
            }
            .padding(.top, 8)
        }
        .font(.system(size: 13, weight: .semibold))
        .padding(16)
        .usageCenterCard()
    }

    private func recentActivityRow(_ task: UsageActivity) -> some View {
        let accent = ControlCenterPalette.providerAccent(task.provider)
        let stateInfo = activityStateInfo(task)
        return HStack(spacing: 10) {
            Circle().fill(accent).frame(width: 7, height: 7)
            Text(groupName(task.provider))
                .font(.system(size: 11.5, weight: .semibold))
                .frame(width: 88, alignment: .leading)
            Text(task.project)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
            Text(task.machine)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.primary.opacity(0.05), in: Capsule())
            Spacer()
            ControlCenterStatusBadge(title: stateInfo.0, color: stateInfo.1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .usageCenterInset(cornerRadius: 8)
    }

    private func activityStateInfo(_ activity: UsageActivity) -> (String, Color) {
        if ["running", "waiting"].contains(activity.state), Date().timeIntervalSince1970 - activity.observedAt > 300 {
            return ("状态待确认", .orange)
        }
        return switch activity.state {
        case "running": ("运行中", .green)
        case "waiting": ("等待批准", .orange)
        case "completed": ("本轮结束", .secondary)
        case "interrupted": ("已中断", .red)
        case "closed": ("会话已结束", .secondary)
        default: ("状态未知", .secondary)
        }
    }

    private func groupName(_ name: String) -> String {
        switch name {
        case "codex": "Codex"
        case "claude": "Claude Code"
        case "gemini": "Gemini (agy)"
        case "oauth": "OAuth"
        case "api": "API"
        case "unknown", "": "未知"
        default: name
        }
    }
}

// MARK: - 侧边栏条目组件

private struct SidebarNavRow: View {
    let title: String
    let subtitle: String
    let symbol: String
    let tint: Color
    let isSelected: Bool
    let badge: String?
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(isSelected ? .white : tint)
                    .frame(width: 26, height: 26)
                    .background(
                        isSelected ? tint : tint.opacity(0.14),
                        in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                    )
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 12.5, weight: isSelected ? .semibold : .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                if let badge {
                    Text(badge)
                        .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                        .foregroundStyle(isSelected ? tint : .secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.primary.opacity(0.06), in: Capsule())
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .background(
                isSelected ? Color.accentColor.opacity(0.14) : isHovered ? Color.primary.opacity(0.05) : .clear,
                in: RoundedRectangle(cornerRadius: 9, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

private struct SidebarDeviceRow: View {
    let source: UsageSource
    let status: UsageSourceStatus?
    let isSelected: Bool
    let canEdit: Bool
    let onSelect: () -> Void
    let onConfigure: () -> Void
    @State private var isHovered = false

    private var iconName: String {
        switch source.transport {
        case .local: "laptopcomputer"
        case .probe: "antenna.radiowaves.left.and.right"
        case .ssh, .https: "server.rack"
        }
    }

    private var dotColor: Color {
        if !source.isEnabled {
            return .secondary.opacity(0.5)
        }
        if status?.error != nil {
            return .orange
        }
        if source.transport == .local {
            return .green
        }
        if source.transport == .probe {
            return source.isOnline ? .green : .orange
        }
        return status?.lastSuccess != nil ? .green : .secondary
    }

    private var subtitleText: String {
        if !source.isEnabled {
            return "已停用"
        }
        if let err = status?.error, !err.isEmpty {
            return err
        }
        if source.transport == .local {
            return "本机实时直读"
        }
        if source.transport == .probe {
            let plat = source.platformName.isEmpty ? "" : " · \(source.platformName)"
            return (source.isOnline ? "探针在线" : "离线待连") + plat
        }
        if let last = status?.lastSuccess {
            return "更新于 " + last.formatted(date: .omitted, time: .shortened)
        }
        return "等待首次同步"
    }

    var body: some View {
        HStack(spacing: 4) {
            Button(action: onSelect) {
                HStack(spacing: 9) {
                    ZStack(alignment: .bottomTrailing) {
                        Image(systemName: iconName)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                            .frame(width: 26, height: 26)
                            .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        Circle()
                            .fill(dotColor)
                            .frame(width: 6.5, height: 6.5)
                            .offset(x: 1.5, y: 1.5)
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(source.name)
                            .font(.system(size: 12.5, weight: isSelected ? .semibold : .regular))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Text(subtitleText)
                            .font(.system(size: 10.5))
                            .foregroundStyle(status?.error != nil ? Color.orange : .secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.leading, 8)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isHovered || isSelected {
                Button(action: onConfigure) {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 24)
                        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(!canEdit)
                .padding(.trailing, 6)
                .help("管理 \(source.name)")
            }
        }
        .background(
            isSelected ? Color.accentColor.opacity(0.14) : isHovered ? Color.primary.opacity(0.05) : .clear,
            in: RoundedRectangle(cornerRadius: 9, style: .continuous)
        )
        .onHover { isHovered = $0 }
    }
}
