import SwiftUI

struct UsageAnalyticsView: View {
    @ObservedObject var model: UsageAnalyticsViewModel
    @State private var visibleCount = 8

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("订阅区间价值").font(.caption.weight(.semibold))
                Spacer()
                if model.isRefreshing || model.isImportingHistory {
                    ProgressView().controlSize(.mini)
                }
                Menu {
                    Menu("同账号历史周限来源") {
                        Text("仅选择 OAuth 历史属于当前账号的设备")
                        Toggle("本机 Mac", isOn: $model.includesLocalHistory)
                        ForEach(model.history.eligibleSources.filter { $0.id != "local" }) { source in
                            Toggle(source.name, isOn: Binding(
                                get: { model.history.isSelected(source) },
                                set: { model.history.setSelected(source, enabled: $0) }
                            ))
                        }
                    }.disabled(model.snapshot == nil)
                    Picker("历史未知档位的周额度参考", selection: $model.quotaReference) {
                        ForEach(UsageQuotaReference.allCases) { Text($0.title).tag($0) }
                    }.disabled(model.snapshot == nil)
                    Link("官方账号分析", destination: URL(string: "https://chatgpt.com/codex/cloud/settings/analytics")!)
                    Link("官方 API 单价", destination: URL(string: "https://developers.openai.com/api/docs/pricing")!)
                } label: { Image(systemName: "ellipsis.circle") }
                    .menuIndicator(.hidden).menuStyle(.borderlessButton).frame(width: 24)
                Button { model.refresh(force: true) } label: { Image(systemName: "arrow.clockwise.circle") }
                    .buttonStyle(.plain).disabled(model.isRefreshing).help("刷新官方账本")
            }
            Text("本机 ChatGPT 账号 · 官方 Codex / Work 账本 · 最近 70 天")
                .font(.caption2).foregroundStyle(.secondary)
            if let error = model.error {
                Text(error).font(.caption2).foregroundStyle(.orange)
            }
            ForEach(model.history.errors.keys.sorted(), id: \.self) { key in
                Text(model.history.errors[key] ?? "").font(.caption2).foregroundStyle(.orange)
            }
            if model.periods.isEmpty {
                Text(model.isRefreshing ? "正在读取官方统计…" : "暂无可验证的周限周期")
                    .font(.caption).foregroundStyle(.secondary).padding(.vertical, 8)
            }
            ForEach(model.periods.prefix(visibleCount)) { period in
                UsagePeriodCard(
                    period: period, estimate: weeklyEstimate(period),
                    isReference: (model.projection(for: period) ?? 0) <= 0 && model.reference(for: period) != .disabled,
                    planTitle: model.planTitle(for: period)
                ) {
                    periodDetails(period)
                }
            }
            if model.periods.count > visibleCount {
                Button("更多周期") { visibleCount += 8 }.buttonStyle(.plain).font(.caption)
            }
            Text("按 Quota Compass 混合单价公式估算模型 Token 和金额。Fast 按订阅额度倍率折合, 不代表实际 API 账单; 缓存写入与长上下文未单列。")
                .font(.caption2).foregroundStyle(.secondary)
            if let snapshot = model.snapshot {
                Text("账本读取 \(snapshot.fetchedAt.formatted(date: .abbreviated, time: .shortened)) · 价格快照 \(model.prices?.asOf ?? "--")")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(14)
        .usageCenterCard()
        .task { model.start() }
    }

    private func weeklyEstimate(_ period: UsageAnalyticsPeriod) -> String {
        if let value = model.projection(for: period), value > 0 {
            return value.formatted(.number.precision(.fractionLength(2))) + "$"
        }
        if let range = model.reference(for: period).dollarRange {
            return range.lowerBound.formatted(.number.precision(.fractionLength(0))) + "–"
                + range.upperBound.formatted(.number.precision(.fractionLength(0))) + "$"
        }
        return "待补齐"
    }

    private func periodDetails(_ period: UsageAnalyticsPeriod) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                value(period.missingDays > 0 || !period.unknownModels.isEmpty ? "已记录部分价值" : "区间折合价值", dollars(period.dollars))
                value("预计周限总额", "≈ " + weeklyEstimate(period))
                value("估算 credits", period.credits.map { "≈ " + $0.formatted(.number.precision(.fractionLength(1))) } ?? "待补齐")
            }
            if (model.projection(for: period) ?? 0) <= 0, model.reference(for: period) != .disabled {
                Text("周限总额采用 \(model.reference(for: period).title) 的参考范围, 按 25 credits = 1 美元换算。它是所选档位的经验值, 不代表该历史区间已被完整测量。")
                    .foregroundStyle(.secondary)
            }
            HStack {
                value("未缓存输入", tokens(period.tokens.input))
                value("输出", tokens(period.tokens.output))
                value("缓存读取", tokens(period.tokens.cached))
                value("缓存写入", "未单列")
            }
            Text("估值对齐至 \(period.valuedThrough.formatted(date: .abbreviated, time: .shortened)), 对应已用 \(period.valuedPercent.formatted(.number.precision(.fractionLength(1))))% 周限")
                .foregroundStyle(.secondary)
            if period.missingDays > 0 {
                Text("\(period.missingDays) 天有额度消耗但 Token 明细缺失, 按已记录样本匹配的 \(period.samplePercent.formatted(.number.precision(.fractionLength(1))))% 周限继续外推").foregroundStyle(.secondary)
            }
            if period.boundaryDays > 0 {
                Text("\(period.boundaryDays) 个边界日按额度增量分摊" + (period.timeAllocatedDays > 0 ? ", 其中 \(period.timeAllocatedDays) 天观察不足, 按覆盖时长估算" : ""))
                    .foregroundStyle(.secondary)
            }
            if !period.unknownModels.isEmpty {
                Text("未确认单价: " + period.unknownModels.joined(separator: ", ")).foregroundStyle(.orange)
            }
            if period.unreliable {
                Text("同一窗口内额度出现回落, 暂停外推").foregroundStyle(.orange)
            }
            if model.planEntries(for: period).count > 1 {
                Text("区间内识别到订阅档位变化: " + model.planTitle(for: period) + ", 参考额度按最后识别的档位展示")
                    .foregroundStyle(.secondary)
            }
            UsageDisclosure(title: "模型估算明细") {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(period.models) { row in
                        UsageDisclosure(title: row.model + (row.speed == "standard" ? "" : " · " + row.speed) + " · " + dollars(row.dollars)) {
                            HStack {
                                value("未缓存输入", tokens(row.tokens.input))
                                value("输出", tokens(row.tokens.output))
                                value("缓存读取", tokens(row.tokens.cached))
                                value("估算 credits", row.credits.map { "≈ " + $0.formatted(.number.precision(.fractionLength(1))) } ?? "--")
                            }
                        }
                    }
                    Text("同一天各模型采用相同输入输出比例, 通过额度权重 ÷ 混合单价反推占比。模型 Token 与 credits 均为估算。")
                        .foregroundStyle(.secondary)
                }
            }
        }.font(.caption2)
    }

    private func value(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).foregroundStyle(.secondary)
            Text(text).fontWeight(.semibold).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func dollars(_ amount: Double?) -> String {
        guard let amount else { return "数据不足" }
        return "≈ " + amount.formatted(.currency(code: "USD").precision(.fractionLength(2)))
    }

    private func tokens(_ value: Int64) -> String {
        "≈ " + value.formatted(.number.notation(.compactName))
    }
}
