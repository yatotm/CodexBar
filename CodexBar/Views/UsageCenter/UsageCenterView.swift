import Charts
import SwiftUI

struct UsageCenterView: View {
    @ObservedObject var viewModel: UsageCenterViewModel
    @State private var editingSource: UsageSource?
    @State private var deletingSource: UsageSource?

    var body: some View {
        VStack(spacing: 0) {
            topWorkspaceBar
            Divider()
            if viewModel.activeSection == .deployment {
                ControlCenterDeploymentView(
                    viewModel: viewModel,
                    editingSource: $editingSource,
                    deletingSource: $deletingSource
                )
            } else {
                usageWorkspace
            }
        }
        .liquidGlassSurface(cornerRadius: 12, isOuterSurface: true)
        .sheet(item: $editingSource) { source in
            UsageSourceEditor(viewModel: viewModel, source: source)
        }
        .alert("移除监控节点?", isPresented: Binding(
            get: { deletingSource != nil }, set: {
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

    private var topWorkspaceBar: some View {
        HStack(spacing: 14) {
            Picker("工作区", selection: $viewModel.activeSection) {
                ForEach(ControlCenterSection.allCases) { section in
                    Text(section.title).tag(section)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 220)
            HStack(spacing: 6) {
                Circle()
                    .fill(hubIndicatorColor)
                    .frame(width: 7, height: 7)
                Text(viewModel.topologyMode.title + " · " + viewModel.hubStatusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Menu {
                Toggle("每 5 分钟自动刷新", isOn: $viewModel.automaticRefresh)
            } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 25).help("刷新设置")
            if viewModel.isRefreshing {
                ProgressView().controlSize(.small)
                Button("停止") { viewModel.cancelRefresh() }.controlSize(.small)
            } else {
                Button { viewModel.refresh() } label: { Image(systemName: "arrow.clockwise") }
                    .keyboardShortcut("r", modifiers: .command).help("刷新统计")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var hubIndicatorColor: Color {
        if viewModel.topologyMode == .localOnly {
            return .blue
        }
        guard let healthy = viewModel.hubHealthy else { return .secondary }
        return healthy ? .green : .orange
    }

    private var usageWorkspace: some View {
        HSplitView {
            sourceList.frame(width: 215)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    providerHeader
                    filters
                    if let error = viewModel.error {
                        Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    }
                    if viewModel.dashboardFilter == viewModel.filter {
                        totals
                        UsageDailyChart(days: viewModel.dashboard.days).padding(14).usageCenterCard()
                        UsageBreakdownView(groups: viewModel.dashboard.groups, grouping: $viewModel.filter.grouping)
                            .padding(14).usageCenterCard()
                        valuationSections
                        UsageDisclosure(title: "额度记录") { quotaSnapshots.padding(.top, 8) }
                            .padding(14).usageCenterCard()
                        UsageDisclosure(title: "最近任务") { activity.padding(.top, 8) }
                            .padding(14).usageCenterCard()
                    } else if viewModel.error == nil {
                        ProgressView("正在查询统计…").frame(maxWidth: .infinity, minHeight: 180)
                    }
                    Text("UTC · 已采集日志 · 跨设备去重")
                        .help("只统计保留的日志, 不代表订阅账单; 不与账号全时累计相加")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(16)
            }
            .frame(minWidth: 640)
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
                    subtitle: "跨节点会话去重 · Gemini 7d 额度锚定 · API 标准单价外推",
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

    private var sourceList: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("节点").font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.horizontal, 14).padding(.top, 14)
            List {
                UsageSourceRow(
                    title: "全部节点",
                    symbol: "desktopcomputer.and.macbook",
                    isSelected: viewModel.filter.sourceID.isEmpty,
                    select: { viewModel.filter.sourceID = "" }, status: { EmptyView() }
                )
                ForEach(viewModel.effectiveSources) { source in
                    UsageSourceRow(
                        title: source.name,
                        symbol: symbolName(for: source),
                        isSelected: viewModel.filter.sourceID == source.id,
                        canEdit: !viewModel.isRefreshing,
                        select: { viewModel.filter.sourceID = source.id },
                        edit: {
                            if source.transport == .probe {
                                viewModel.activeSection = .deployment
                            } else {
                                editingSource = source
                            }
                        },
                        status: { sourceState(source) }
                    )
                    .contextMenu {
                        if source.transport == .probe {
                            Button("前往节点与部署管理") { viewModel.activeSection = .deployment }
                        } else {
                            Button("编辑节点") { editingSource = source }
                                .disabled(viewModel.isRefreshing)
                        }
                        if source.id != "local" {
                            Button("移除节点", role: .destructive) { deletingSource = source }
                                .disabled(viewModel.isRefreshing)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .environment(\.defaultMinListRowHeight, 40)
            .scrollContentBackground(.hidden)
            Button {
                viewModel.activeSection = .deployment
            } label: {
                Label("节点与探针管理", systemImage: "antenna.radiowaves.left.and.right")
            }
            .padding(14)
        }
        .background(.ultraThinMaterial)
    }

    private func symbolName(for source: UsageSource) -> String {
        switch source.transport {
        case .local: "laptopcomputer"
        case .probe: "antenna.radiowaves.left.and.right"
        case .ssh, .https: "server.rack"
        }
    }

    @ViewBuilder private func sourceState(_ source: UsageSource) -> some View {
        let status = viewModel.statuses[source.id]
        ActivityConnectionStatus(controller: viewModel.remoteActivity, sourceID: source.id)
        if !source.isEnabled {
            Text("已暂停").foregroundStyle(.secondary).font(.caption)
        } else if source.transport == .probe {
            Text(source.isOnline ? "探针在线" : "离线待连")
                .foregroundStyle(source.isOnline ? Color.secondary : Color.orange)
                .font(.caption)
        } else if let error = status?.error {
            Text(error).foregroundStyle(.orange).font(.caption)
        } else if let date = status?.lastSuccess {
            Text("更新于 \(date.formatted(date: .abbreviated, time: .shortened))").foregroundStyle(.secondary).font(.caption)
        } else {
            Text("尚未采集").foregroundStyle(.secondary).font(.caption)
        }
        ForEach(status?.warnings ?? [], id: \.self) { warning in
            Text(warning).font(.caption).foregroundStyle(.orange)
        }
    }

    private var availableFilterScopes: [UsageMenuScope] {
        let providers = viewModel.activeProviders
        if providers.count <= 1 {
            return providers.isEmpty ? [.codex] : providers
        }
        return [.all] + providers
    }

    @ViewBuilder
    private var providerHeader: some View {
        let scopes = availableFilterScopes
        if scopes.count > 1 {
            HStack(spacing: 16) {
                Picker("工具", selection: $viewModel.filter.provider) {
                    ForEach(scopes) { Text($0.title).tag($0.rawValue) }
                }
                .pickerStyle(.segmented).labelsHidden()
                .frame(maxWidth: scopes.count >= 4 ? 360 : 280)
                Spacer()
            }
        }
    }

    private var filters: some View {
        HStack(spacing: 12) {
            Text(viewModel.effectiveSources.first { $0.id == viewModel.filter.sourceID }?.name ?? "全部节点")
                .font(.headline)
            Spacer()
            Picker("登录", selection: $viewModel.filter.authentication) {
                Text("全部").tag("")
                ForEach(UsageAuthentication.allCases) { Text($0.title).tag($0.rawValue) }
            }.fixedSize()
            Picker("时间", selection: $viewModel.filter.days) {
                Text("今天").tag(1)
                Text("7 天").tag(7)
                Text("30 天").tag(30)
                Text("90 天").tag(90)
                Text("210 天").tag(210)
            }.fixedSize()
        }.pickerStyle(.menu).controlSize(.small)
    }

    private var totals: some View {
        let metrics = viewModel.dashboard.totals
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                metric("已采集 Token", metrics.tokens)
                metric("会话", metrics.sessions)
                metric("对话轮次", metrics.turns)
                metric("工具调用", metrics.tools)
            }
            UsageDisclosure(title: "更多指标") {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: 4), spacing: 14) {
                    metric("输入 Token", metrics.input)
                    metric("输出 Token", metrics.output)
                    metric("缓存读取", metrics.cacheRead)
                    metric("缓存写入", metrics.cacheWrite)
                    metric("子智能体", metrics.subagents)
                    metric("上下文压缩", metrics.compactions)
                    metric("已记录权限请求", metrics.permissions > 0 ? metrics.permissions : nil)
                    metric("最长单轮秒数", viewModel.dashboard.longestTurnMs.map { $0 / 1000 })
                }.padding(.top, 12)
            }.font(.caption).foregroundStyle(.secondary)
        }
        .padding(16)
        .usageCenterCard()
    }

    private func metric(_ title: String, _ value: Int64?) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value?.formatted(.number.notation(.compactName)) ?? "未知")
                .font(.system(size: 18, weight: .semibold, design: .rounded)).monospacedDigit()
                .foregroundStyle(.primary).lineLimit(1).minimumScaleFactor(0.8)
                .help(value?.formatted() ?? "日志没有提供可靠记录")
        }.frame(maxWidth: .infinity, alignment: .leading)
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

    private var quotaSnapshots: some View {
        VStack(alignment: .leading, spacing: 12) {
            let entries = visibleQuotas
            Text("当前采用的额度记录置顶, 其他记录以灰色显示; Claude 与 Gemini 优先显示有效且带完整 5h/7d 重置时间的记录, 跨机器额度不相加")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(entries) { entry in
                let latest = entries.first(where: { $0.quota.provider == entry.quota.provider })?.id == entry.id
                quotaRow(source: entry.source, quota: entry.quota)
                    .foregroundStyle(latest ? Color.primary : Color.secondary.opacity(0.55))
            }
        }
    }

    private var visibleQuotas: [QuotaEntry] {
        var entries: [QuotaEntry] = []
        for source in viewModel.effectiveSources where source.isEnabled {
            guard viewModel.filter.sourceID.isEmpty || viewModel.filter.sourceID == source.id else { continue }
            for quota in viewModel.statuses[source.id]?.quotas ?? [] {
                guard viewModel.filter.provider.isEmpty || viewModel.filter.provider == quota.provider else { continue }
                let included: Bool = switch quota.provider {
                case "codex": source.includesCodex
                case "claude": source.includesClaude
                case "gemini": source.includesGemini
                default: false
                }
                if included {
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

    private func quotaRow(source: UsageSource, quota: UsageQuotaObservation) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("\(source.name) · \(groupName(quota.provider))")
                .font(.caption.weight(.medium))
            Text(quota.windows.map { window in
                let expired = window.resetsAt.map { $0 <= Date().timeIntervalSince1970 } ?? false
                let value = expired ? "等待新记录" : "剩余 \(Int(100 - window.usedPercent))%"
                let reset = window.resetsAt.map {
                    " (" + Date(timeIntervalSince1970: $0).formatted(.dateTime.month().day().hour().minute()) + ")"
                } ?? ""
                return window.name + " " + value + reset
            }.joined(separator: "  |  "))
                .font(.caption.monospacedDigit())
                .help("记录时间: " + Date(timeIntervalSince1970: quota.observedAt).formatted())
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private var activity: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(viewModel.dashboard.activities.prefix(12)) { task in
                HStack {
                    Image(systemName: "circle.fill").font(.system(size: 7)).foregroundStyle(.secondary)
                    Text("\(task.machine) · \(groupName(task.provider)) · \(task.project)").lineLimit(1)
                    Spacer()
                    Text(activityState(task)).foregroundStyle(.secondary)
                }.font(.caption)
            }
            Text("超过 5 分钟没有进展的运行状态显示为待确认; 远程节点与 Claude / Gemini 任务不参与本机 Codex 的防睡眠判定")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func activityState(_ activity: UsageActivity) -> String {
        if ["running", "waiting"].contains(activity.state), Date().timeIntervalSince1970 - activity.observedAt > 300 {
            return "状态待确认"
        }
        switch activity.state {
        case "running": return "运行中"
        case "waiting": return "等待批准"
        case "completed": return "本轮结束"
        case "interrupted": return "已中断"
        case "closed": return "会话已结束"
        default: return "状态未知"
        }
    }
}

private struct ActivityConnectionStatus: View {
    @ObservedObject var controller: RemoteActivityController
    let sourceID: String

    var body: some View {
        if controller.enabledSourceIDs.contains(sourceID) {
            Text(controller.states[sourceID] ?? "未连接").font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct UsageSourceRow<Status: View>: View {
    let title: String
    let symbol: String
    let isSelected: Bool
    var canEdit = true
    let select: () -> Void
    var edit: (() -> Void)?
    @ViewBuilder let status: () -> Status
    @State private var isHovered = false
    @State private var isEditHovered = false

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Button(action: select) {
                VStack(alignment: .leading, spacing: 6) {
                    Label(title, systemImage: symbol)
                        .fontWeight(isSelected ? .semibold : .regular)
                        .lineLimit(1)
                    status()
                }
                .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
                .padding(10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(title)
            .accessibilityValue(isSelected ? "已选中" : "未选中")
            if let edit {
                Button(action: edit) {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(isEditHovered ? Color.accentColor : .secondary)
                        .frame(width: 30, height: 30)
                        .background(isEditHovered ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 6))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!canEdit)
                .onHover { isEditHovered = $0 }
                .help("配置 " + title)
                .accessibilityLabel("配置 " + title)
                .padding(.top, 7)
                .padding(.trailing, 6)
            }
        }
        .background(
            isSelected ? Color.accentColor.opacity(0.12) : isHovered ? Color.primary.opacity(0.055) : .clear,
            in: RoundedRectangle(cornerRadius: 8)
        )
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovered)
        .animation(.easeOut(duration: 0.12), value: isEditHovered)
        .listRowInsets(EdgeInsets(top: 3, leading: 4, bottom: 3, trailing: 4))
        .listRowBackground(Color.clear)
    }
}

extension View {
    /// 滚动卡片只绘制底色和细边框, 避免为每张长卡片重复合成玻璃阴影
    func usageCenterCard() -> some View {
        background(Color(nsColor: .controlBackgroundColor).opacity(0.72), in: RoundedRectangle(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12).strokeBorder(.primary.opacity(0.07), lineWidth: 0.8)
                    .allowsHitTesting(false)
            }
    }
}
