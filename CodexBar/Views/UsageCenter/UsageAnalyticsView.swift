import SwiftUI

struct UsageAnalyticsView: View {
    @ObservedObject var model: UsageAnalyticsViewModel
    @State private var visibleCount = 8

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            headerBar
            if let error = model.error {
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
            Text("订阅价值按标准 API 单价与订阅内加速倍率估算; 官方明细缺失时自动回退至同账号设备日志")
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

    @ViewBuilder
    private func periodDetails(_ period: UsageAnalyticsPeriod) -> some View {
        if let estimate = period.logEstimate {
            logDetails(period, estimate: estimate)
        } else {
            officialDetails(period)
        }
    }

    private func logDetails(_ period: UsageAnalyticsPeriod, estimate: UsageLogEstimate) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("设备日志估算 · " + estimate.sources.joined(separator: " / "))
                .fontWeight(.medium).foregroundStyle(.secondary)
            HStack(spacing: 12) {
                value("已记录折合价值", "≈ $" + rangeText(estimate.dollars))
                value("预计周限总额", "≈ " + weeklyEstimate(period))
                value("估算 credits", estimate.credits.map { "≈ " + rangeText($0) } ?? "待补齐")
            }
            HStack(spacing: 12) {
                value("未缓存输入", tokens(estimate.tokens.input))
                value("模型输出", tokens(estimate.tokens.output))
                value("缓存读取", tokens(estimate.tokens.cached))
            }
            Text("日志对齐至 \(estimate.valuedThrough.formatted(date: .abbreviated, time: .shortened)), 对应已用 \(estimate.usedPercent.formatted(.number.precision(.fractionLength(1))))% 周限")
                .foregroundStyle(.secondary)
            if estimate.unknownSpeedCount > 0 {
                Text("\(estimate.unknownSpeedCount) 条记录缺少速度设置, 金额按标准至该模型当时可用的最高加速档估算")
                    .foregroundStyle(.secondary)
            }
            if estimate.incomplete {
                Text("部分设备或历史记录尚未补齐, 当前估值可能偏低").foregroundStyle(.orange)
            }
            if !estimate.unknownModels.isEmpty {
                Text("未计价: " + estimate.unknownModels.joined(separator: ", ")).foregroundStyle(.orange)
            }
            if period.unreliable || model.planEntries(for: period).count > 1 {
                Text("周期内额度回落或订阅档位变化, 暂停周限外推").foregroundStyle(.orange)
            }
            Divider().opacity(0.5)
            UsageDisclosure(title: "按模型查看用量明细 (\(estimate.models.count))") {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(estimate.models) { row in
                        UsageDisclosure(title: row.model + speedTitle(row.speed) + " · ≈ $" + rangeText(row.dollars)) {
                            HStack(spacing: 12) {
                                value("未缓存输入", tokens(row.tokens.input))
                                value("模型输出", tokens(row.tokens.output))
                                value("缓存读取", tokens(row.tokens.cached))
                            }
                            apiUnitPrices(for: row.model, speed: row.speed, start: period.start, end: estimate.valuedThrough)
                        }
                    }
                }
            }
            Text("按已记录的模型和速度比例外推; 纯云端任务可能未包含, 官方明细补齐后自动替换本估算且不重复累计")
                .foregroundStyle(.tertiary)
        }
        .font(.system(size: 11.5))
    }

    @ViewBuilder
    private func apiUnitPrices(for name: String, speed: String?, start: Date, end: Date) -> some View {
        if let rate = model.prices?.rate(for: name) {
            let tier = speed?.lowercased() ?? "standard"
            let multiplier = rate.apiMultiplier(for: tier, start: start, end: end)
            let label = multiplier == nil || ["standard", "default", ""].contains(tier) ? "Standard" : tier == "priority" ? "Fast" : tier.capitalized
            let factors = multiplier ?? 1 ... 1
            Text("短上下文 API \(label) / 百万 Token · 输入 \(unitPrice(rate.input, factors)) · 缓存读取 \(unitPrice(rate.cachedInput, factors)) · 输出 \(unitPrice(rate.output, factors))")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
            if let short = rate.cacheWrite, let extended = rate.cacheWrite12h {
                Text("缓存写入 / 百万 Token · 30 分钟 \(unitPrice(short, factors)) · 12 小时 \(unitPrice(extended, factors))")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func unitPrice(_ amount: Double, _ range: ClosedRange<Double>) -> String {
        let format = FloatingPointFormatStyle<Double>.Currency(code: "USD").precision(.fractionLength(0 ... 4))
        let lower = (range.lowerBound * amount).formatted(format)
        return range.lowerBound == range.upperBound ? lower : lower + "–" + (range.upperBound * amount).formatted(format)
    }

    private func speedTitle(_ speed: String?) -> String {
        guard let speed else { return " · 速度未记录" }
        return speed == "standard" ? "" : " · " + speed
    }

    private func rangeText(_ range: ClosedRange<Double>) -> String {
        let lower = range.lowerBound.formatted(.number.precision(.fractionLength(2)))
        let upper = range.upperBound.formatted(.number.precision(.fractionLength(2)))
        return lower == upper ? lower : lower + "–" + upper
    }

    private func officialDetails(_ period: UsageAnalyticsPeriod) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                value(period.missingDays > 0 || !period.unknownModels.isEmpty ? "已记录部分价值" : "区间折合价值", dollars(period.dollars))
                value("预计周限总额", "≈ " + weeklyEstimate(period))
                value("估算 credits", period.credits.map { "≈ " + $0.formatted(.number.precision(.fractionLength(1))) } ?? "待补齐")
            }
            if (model.projection(for: period)?.upperBound ?? 0) <= 0, model.reference(for: period) != .disabled {
                Text("周限总额采用 \(model.reference(for: period).title) 的参考范围, 按 25 credits = 1 美元换算; 该值为经验参考而非完整测量")
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                value("未缓存输入", tokens(period.tokens.input))
                value("模型输出", tokens(period.tokens.output))
                value("缓存读取", tokens(period.tokens.cached))
                value("缓存写入", "未单列")
            }
            Text("估值对齐至 \(period.valuedThrough.formatted(date: .abbreviated, time: .shortened)), 对应已用 \(period.valuedPercent.formatted(.number.precision(.fractionLength(1))))% 周限")
                .foregroundStyle(.secondary)
            officialWarnings(period)
            Divider().opacity(0.5)
            UsageDisclosure(title: "按模型查看估算明细 (\(period.models.count))") {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(period.models) { row in
                        UsageDisclosure(title: row.model + (row.speed == "standard" ? "" : " · " + row.speed) + " · " + dollars(row.dollars)) {
                            HStack(spacing: 12) {
                                value("未缓存输入", tokens(row.tokens.input))
                                value("模型输出", tokens(row.tokens.output))
                                value("缓存读取", tokens(row.tokens.cached))
                                value("估算 credits", row.credits.map { "≈ " + $0.formatted(.number.precision(.fractionLength(1))) } ?? "--")
                            }
                            apiUnitPrices(for: row.model, speed: row.speed, start: period.start, end: period.valuedThrough)
                        }
                    }
                    Text("同一天各模型采用相同输入输出比例, 通过额度权重除以混合单价反推占比; 模型 Token 与 credits 均为估算")
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .font(.system(size: 11.5))
    }

    @ViewBuilder
    private func officialWarnings(_ period: UsageAnalyticsPeriod) -> some View {
        if period.missingDays > 0 {
            Text("\(period.missingDays) 天有额度消耗但 Token 明细缺失, 按已记录样本匹配的 \(period.samplePercent.formatted(.number.precision(.fractionLength(1))))% 周限继续外推")
                .foregroundStyle(.secondary)
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
    }

    private func value(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 11)).foregroundStyle(.secondary)
            Text(text).font(.system(size: 13, weight: .semibold, design: .rounded)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func dollars(_ amount: Double?) -> String {
        guard let amount else { return "数据不足" }
        return "≈ " + amount.formatted(.currency(code: "USD").precision(.fractionLength(2)))
    }

    private func tokens(_ value: Int64) -> String {
        "≈ " + value.formatted(.number.notation(.compactName))
    }
}
