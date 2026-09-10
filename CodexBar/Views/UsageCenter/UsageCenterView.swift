import Charts
import SwiftUI

struct UsageCenterView: View {
    @ObservedObject var viewModel: UsageCenterViewModel
    @State private var editingSource: UsageSource?
    @State private var deletingSource: UsageSource?

    var body: some View {
        HSplitView {
            sourceList.frame(width: 215)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    header
                    filters
                    if let error = viewModel.error {
                        Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    }
                    if viewModel.dashboardFilter == viewModel.filter {
                        totals
                        UsageDailyChart(days: viewModel.dashboard.days).padding(14).liquidGlassSurface(cornerRadius: 12)
                        UsageBreakdownView(groups: viewModel.dashboard.groups, grouping: $viewModel.filter.grouping).padding(14).liquidGlassSurface(cornerRadius: 12)
                        if viewModel.filter.provider != "claude", viewModel.filter.authentication != "api" {
                            UsageAnalyticsView(model: viewModel.analytics)
                        }
                        UsageDisclosure(title: "额度记录") { quotaSnapshots.padding(.top, 8) }
                            .padding(14).liquidGlassSurface(cornerRadius: 12)
                        UsageDisclosure(title: "最近任务") { activity.padding(.top, 8) }
                            .padding(14).liquidGlassSurface(cornerRadius: 12)
                    } else if viewModel.error == nil {
                        ProgressView("正在查询统计…").frame(maxWidth: .infinity, minHeight: 180)
                    }
                    Text("UTC · 已采集日志 · 跨设备去重")
                        .help("只统计保留的日志, 不代表订阅账单; 不与 Codex 账号全时累计相加")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(16)
            }
            .frame(minWidth: 640)
        }
        .liquidGlassSurface(cornerRadius: 12, isOuterSurface: true)
        .sheet(item: $editingSource) { source in
            UsageSourceEditor(viewModel: viewModel, source: source)
        }
        .alert("移除统计来源?", isPresented: Binding(
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
            Text("移除此来源在本机的统计缓存和服务令牌。")
        }
    }

    private var sourceList: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("设备").font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.horizontal, 14).padding(.top, 18)
            List {
                Button { viewModel.filter.sourceID = "" } label: {
                    Label("全部机器", systemImage: "desktopcomputer.and.macbook").fontWeight(viewModel.filter.sourceID.isEmpty ? .semibold : .regular)
                }.buttonStyle(.plain)
                ForEach(viewModel.sources) { source in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Button { viewModel.filter.sourceID = source.id } label: {
                                Label(source.name, systemImage: source.transport == .local ? "laptopcomputer" : "server.rack")
                                    .fontWeight(viewModel.filter.sourceID == source.id ? .semibold : .regular)
                            }.buttonStyle(.plain)
                            Spacer()
                            Button { editingSource = source } label: { Image(systemName: "slider.horizontal.3") }
                                .buttonStyle(.plain).disabled(viewModel.isRefreshing).help("编辑来源")
                        }
                        sourceState(source)
                    }
                    .padding(.vertical, 5)
                    .listRowBackground(viewModel.filter.sourceID == source.id ? Color.accentColor.opacity(0.12) : Color.clear)
                    .contextMenu {
                        Button("编辑来源") { editingSource = source }
                            .disabled(viewModel.isRefreshing)
                        if source.id != "local" {
                            Button("移除来源", role: .destructive) { deletingSource = source }.disabled(viewModel.isRefreshing)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            Button { editingSource = UsageSource() } label: {
                Label("添加来源", systemImage: "plus")
            }.disabled(viewModel.isRefreshing).padding(14)
        }
        .background(.ultraThinMaterial)
    }

    @ViewBuilder private func sourceState(_ source: UsageSource) -> some View {
        let status = viewModel.statuses[source.id]
        if !source.isEnabled {
            Text("已暂停").foregroundStyle(.secondary).font(.caption)
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

    private var header: some View {
        HStack(spacing: 16) {
            Picker("工具", selection: $viewModel.filter.provider) {
                ForEach(UsageMenuScope.allCases) { Text($0.title).tag($0.rawValue) }
            }
            .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 330)
            Spacer()
            Menu {
                Toggle("每 5 分钟刷新", isOn: $viewModel.automaticRefresh)
            } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 25).help("刷新设置")
            if viewModel.isRefreshing {
                ProgressView().controlSize(.small)
                Button("停止") { viewModel.cancelRefresh() }
            } else {
                Button { viewModel.refresh() } label: { Image(systemName: "arrow.clockwise") }
                    .keyboardShortcut("r", modifiers: .command).help("刷新统计")
            }
        }
    }

    private var filters: some View {
        HStack(spacing: 12) {
            Text(viewModel.sources.first { $0.id == viewModel.filter.sourceID }?.name ?? "全部设备")
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
        .liquidGlassSurface(cornerRadius: 12)
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
        case "oauth": "OAuth"
        case "api": "API"
        case "unknown", "": "未知"
        default: name
        }
    }

    private var quotaSnapshots: some View {
        VStack(alignment: .leading, spacing: 12) {
            let entries = visibleQuotas
            Text("同账号各工具的最新记录置顶, 较早记录以灰色显示。额度不相加, 没有新观察时不推算。")
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
        for source in viewModel.sources where source.isEnabled {
            guard viewModel.filter.sourceID.isEmpty || viewModel.filter.sourceID == source.id else { continue }
            for quota in viewModel.statuses[source.id]?.quotas ?? [] {
                guard viewModel.filter.provider.isEmpty || viewModel.filter.provider == quota.provider else { continue }
                let included = quota.provider == "codex" ? source.includesCodex : source.includesClaude
                if included {
                    entries.append(QuotaEntry(source: source, quota: quota))
                }
            }
        }
        let newest = Dictionary(grouping: entries, by: { $0.quota.provider }).mapValues {
            $0.max { $0.quota.observedAt < $1.quota.observedAt }?.id
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
            Text("超过 5 分钟没有进展的运行状态显示为待确认。远程记录和 Claude 记录不参与本机 Codex 的防睡眠判定。")
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
