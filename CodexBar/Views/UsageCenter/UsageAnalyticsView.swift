import SwiftUI

struct UsageAnalyticsView: View {
    @ObservedObject var model: UsageAnalyticsViewModel
    @State private var visibleCount = 8

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            headerBar
            if let error = model.error, model.periods.isEmpty {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.orange)
            }
            ForEach(model.history.errors.keys.sorted(), id: \.self) { key in
                if let err = model.history.errors[key], !err.isEmpty {
                    Text(err).font(.system(size: 11.5)).foregroundStyle(.orange)
                }
            }
            if model.periods.isEmpty {
                emptyPlaceholder
            } else {
                VStack(spacing: 4) {
                    ForEach(model.periods.prefix(visibleCount)) { period in
                        UsagePeriodCard(
                            period: period,
                            estimate: weeklyEstimate(period),
                            isReference: (model.projection(for: period)?.upperBound ?? 0) <= 0 && model.reference(for: period) != .disabled,
                            planTitle: model.planTitle(for: period)
                        ) {
                            periodDetails(period)
                        }
                    }
                }
            }
            if model.periods.count > visibleCount {
                Button("展开更多历史周期") { visibleCount += 8 }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(ControlCenterPalette.codex)
            }
            footerCaption
        }
        .padding(16)
        .usageCenterCard()
        .task { model.start() }
    }

    private var headerBar: some View {
        ControlCenterSectionHeader(
            title: "Codex 订阅区间价值",
            subtitle: "当前 ChatGPT 账号 · 官方账本优先 · 同账号设备日志兜底",
            symbol: "dollarsign.circle.fill",
            tint: ControlCenterPalette.codex
        ) {
            HStack(spacing: 4) {
                if model.isRefreshing || model.isImportingHistory {
                    ProgressView().controlSize(.mini).padding(.trailing, 4)
                }
                optionsMenu
                ControlCenterIconButton(
                    symbol: "arrow.clockwise",
                    helpText: "刷新 Codex 价值统计",
                    isDisabled: model.isRefreshing,
                    action: { model.refresh(force: true) }
                )
            }
        }
    }

    private var optionsMenu: some View {
        Menu {
            Menu("同账号设备日志来源") {
                Text("仅选择 OAuth 历史属于当前账号的设备")
                Toggle("本机 Mac", isOn: $model.includesLocalHistory)
                ForEach(model.history.eligibleSources.filter { $0.id != "local" }) { source in
                    Toggle(source.name, isOn: Binding(
                        get: { model.history.isSelected(source) },
                        set: { model.history.setSelected(source, enabled: $0) }
                    ))
                }
            }
            .disabled(model.snapshot == nil)
            Picker("历史未知档位的周额度参考", selection: $model.quotaReference) {
                ForEach(UsageQuotaReference.allCases) { Text($0.title).tag($0) }
            }
            .disabled(model.snapshot == nil)
            Divider()
            Link("官方账号分析", destination: URL(string: "https://chatgpt.com/codex/cloud/settings/analytics")!)
            Link("官方 API 单价", destination: URL(string: "https://developers.openai.com/api/docs/pricing")!)
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
        }
        .menuIndicator(.hidden)
        .menuStyle(.borderlessButton)
        .frame(width: 28)
    }

    private var emptyPlaceholder: some View {
        HStack(spacing: 10) {
            Image(systemName: "chart.line.uptrend.xyaxis")
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
            Text(model.isRefreshing ? "正在读取官方统计…" : "暂无可验证的周限周期")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .usageCenterInset(cornerRadius: 9)
    }

    private var footerCaption: some View {
        HStack {
            Spacer()
            if let snapshot = model.snapshot {
                Text("账本 \(snapshot.fetchedAt.formatted(date: .abbreviated, time: .shortened)) · 单价 \(model.prices?.asOf ?? "--")")
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(.tertiary)
    }

    private func weeklyEstimate(_ period: UsageAnalyticsPeriod) -> String {
        if let value = model.projection(for: period), value.upperBound > 0 {
            return "$" + rangeText(value)
        }
        if let range = model.reference(for: period).dollarRange {
            return "$" + range.lowerBound.formatted(.number.precision(.fractionLength(0))) + "–"
                + range.upperBound.formatted(.number.precision(.fractionLength(0)))
        }
        return "待补齐"
    }

    private func rangeText(_ range: ClosedRange<Double>) -> String {
        let lower = range.lowerBound.formatted(.number.precision(.fractionLength(2)))
        let upper = range.upperBound.formatted(.number.precision(.fractionLength(2)))
        return lower == upper ? lower : lower + "–" + upper
    }

    private func recordedUsage(_ period: UsageAnalyticsPeriod) -> UsageCreditPart {
        if let result = period.creditEstimate {
            return result.recorded
        }
        let log = period.logEstimate
        var result = UsageCreditPart(tokens: log?.tokens ?? period.tokens)
        if let log {
            for row in log.models {
                result.modelTokens[row.model, default: .zero] += row.tokens
                if let amount = row.credits {
                    result.addModelCredits(amount, for: row.model)
                }
            }
        } else {
            for row in period.models {
                result.modelTokens[row.model, default: .zero] += row.tokens
                if let amount = row.credits {
                    result.addModelCredits(amount ... amount, for: row.model)
                }
            }
        }
        return result
    }

    private func periodDetails(_ period: UsageAnalyticsPeriod) -> some View {
        let part = recordedUsage(period)
        let legacy = model.snapshot?.readCreditReports != true
        let credits = period.creditEstimate?.recorded.credits ?? (legacy ? period.logEstimate?.credits ?? period.credits.map { $0 ... $0 } : nil)
        let amount = period.creditEstimate.map { UsageCreditEstimate.dollars($0.recorded.credits) }
            ?? (legacy ? period.logEstimate?.dollars ?? period.dollars.map { $0 ... $0 } : nil)
        let names = Set(part.modelTokens.keys).union(part.modelCredits.keys).sorted { lhs, rhs in
            let left = part.modelCredits[lhs]?.upperBound ?? 0
            let right = part.modelCredits[rhs]?.upperBound ?? 0
            return left == right ? lhs < rhs : left > right
        }
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                value("已记录折合价值", amount.map { "≈ $" + rangeText($0) } ?? "—")
                value("预计周限", "≈ " + weeklyEstimate(period))
                value("已记录 credits", credits.map(rangeText) ?? "—")
            }
            if let count = part.tokens {
                tokenRow(count).help("已记录的 Token 总量")
            }
            if !names.isEmpty {
                UsageDisclosure(title: "按模型查看用量 (\(names.count))") {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(names, id: \.self) { name in
                            let amount = part.modelCredits[name].map { " · ≈ $" + rangeText(UsageCreditEstimate.dollars($0)) } ?? ""
                            if let count = part.modelTokens[name] {
                                UsageDisclosure(title: name + amount) { tokenRow(count) }
                            } else {
                                Text(name + amount)
                            }
                        }
                    }
                }
            }
        }
        .font(.system(size: 11.5))
    }

    private func tokenRow(_ count: AnalyticsTokens) -> some View {
        HStack(spacing: 12) {
            value("未缓存输入", tokens(count.input))
            value("模型输出", tokens(count.output))
            value("缓存读取", tokens(count.cached))
        }
    }

    private func value(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 11)).foregroundStyle(.secondary)
            Text(text).font(.system(size: 13, weight: .semibold, design: .rounded)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func tokens(_ value: Int64) -> String {
        "≈ " + value.formatted(.number.notation(.compactName))
    }
}
