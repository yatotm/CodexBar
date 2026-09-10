import Foundation

/// 与 Quota Compass 相同的混合单价反推, 各模型假设采用当天相同的输入输出比例
nonisolated enum UsageModelAllocation {
    static func multiplier(model: AnalyticsModel, prices: UsagePriceBook) -> Double? {
        guard let rate = prices.rate(for: model.model) else { return nil }
        switch model.speed.lowercased() {
        case "standard", "": return 1
        case "flex": return 0.5
        case "fast":
            if rate.model.hasPrefix("gpt-5.4") {
                return 2
            }
            if rate.model == "gpt-6-astra" || rate.model.hasPrefix("gpt-5.6") || rate.model == "gpt-5.5" {
                return 2.5
            }
            return nil
        default: return nil
        }
    }

    static func estimate(day: AnalyticsDay, prices: UsagePriceBook) -> [UsageModelEstimate]? {
        guard let tokens = day.tokens else { return nil }
        if tokens.total == 0 {
            return []
        }
        let models = day.models.filter { $0.weight > 0 }
        guard !models.isEmpty else { return nil }
        var inverse: [Double] = []
        for model in models {
            guard let rate = prices.rate(for: model.model), let factor = multiplier(model: model, prices: prices) else { return nil }
            let mixed = (Double(tokens.input) * rate.input + Double(tokens.cached) * rate.cachedInput + Double(tokens.output) * rate.output)
                * factor / Double(tokens.total)
            guard mixed.isFinite, mixed > 0 else { return nil }
            inverse.append(model.weight / mixed)
        }
        let sum = inverse.reduce(0, +)
        guard sum.isFinite, sum > 0 else { return nil }
        let shares = inverse.map { $0 / sum }
        let input = allocate(tokens.input, shares: shares)
        let cached = allocate(tokens.cached, shares: shares)
        let output = allocate(tokens.output, shares: shares)
        return models.enumerated().map { index, model in
            let rate = prices.rate(for: model.model)!
            let factor = multiplier(model: model, prices: prices)!
            let dollars = (Double(input[index]) * rate.input + Double(cached[index]) * rate.cachedInput + Double(output[index]) * rate.output)
                * factor / 1000000
            let credits: Double? = if let creditInput = rate.creditInput, let creditCache = rate.creditCachedInput, let creditOutput = rate.creditOutput {
                (Double(input[index]) * creditInput + Double(cached[index]) * creditCache + Double(output[index]) * creditOutput)
                    * factor / 1000000
            } else {
                nil
            }
            return UsageModelEstimate(
                model: model.model,
                speed: model.speed,
                tokens: AnalyticsTokens(input: input[index], cached: cached[index], output: output[index]),
                dollars: dollars,
                credits: credits,
                weight: model.weight
            )
        }
    }

    static func scaled(_ tokens: AnalyticsTokens, by share: Double) -> AnalyticsTokens {
        AnalyticsTokens(
            input: Int64((Double(tokens.input) * share).rounded()),
            cached: Int64((Double(tokens.cached) * share).rounded()),
            output: Int64((Double(tokens.output) * share).rounded())
        )
    }

    private static func allocate(_ total: Int64, shares: [Double]) -> [Int64] {
        let raw = shares.map { Double(total) * $0 }
        var values = raw.map { Int64($0.rounded(.down)) }
        var remaining = total - values.reduce(0, +)
        let order = shares.indices.sorted {
            let lhs = raw[$0] - Double(values[$0])
            let rhs = raw[$1] - Double(values[$1])
            return lhs == rhs ? $0 < $1 : lhs > rhs
        }
        for index in order where remaining > 0 {
            values[index] += 1
            remaining -= 1
        }
        return values
    }
}
