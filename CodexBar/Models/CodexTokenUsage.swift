import Foundation

nonisolated struct CodexTokenUsage: Codable, Equatable {
    let inputTokens: Int64
    let cachedInputTokens: Int64
    let cacheWriteInputTokens: Int64
    let outputTokens: Int64
    let reasoningOutputTokens: Int64?
    let totalTokens: Int64

    init(
        inputTokens: Int64,
        cachedInputTokens: Int64,
        cacheWriteInputTokens: Int64,
        outputTokens: Int64,
        reasoningOutputTokens: Int64? = nil,
        totalTokens: Int64
    ) {
        self.inputTokens = inputTokens
        self.cachedInputTokens = cachedInputTokens
        self.cacheWriteInputTokens = cacheWriteInputTokens
        self.outputTokens = outputTokens
        self.reasoningOutputTokens = reasoningOutputTokens
        self.totalTokens = totalTokens
    }

    init(from decoder: Decoder) throws {
        if let snake = try? decoder.container(keyedBy: CodingKeys.self), snake.contains(.inputTokens) {
            inputTokens = try snake.decode(Int64.self, forKey: .inputTokens)
            cachedInputTokens = try snake.decode(Int64.self, forKey: .cachedInputTokens)
            cacheWriteInputTokens = try snake.decodeIfPresent(Int64.self, forKey: .cacheWriteInputTokens) ?? 0
            outputTokens = try snake.decode(Int64.self, forKey: .outputTokens)
            reasoningOutputTokens = try snake.decodeIfPresent(Int64.self, forKey: .reasoningOutputTokens)
            totalTokens = try snake.decode(Int64.self, forKey: .totalTokens)
            return
        }
        let camel = try decoder.container(keyedBy: CamelCodingKeys.self)
        let rawIn = try camel.decode(Int64.self, forKey: .inputTokens)
        let cr = try camel.decodeIfPresent(Int64.self, forKey: .cachedInputTokens) ?? 0
        let cw = try camel.decodeIfPresent(Int64.self, forKey: .cacheWriteInputTokens) ?? 0
        let out = try camel.decode(Int64.self, forKey: .outputTokens)
        let total = try camel.decodeIfPresent(Int64.self, forKey: .totalTokens) ?? (rawIn + cr + cw + out)
        let normalizedIn = rawIn < cr + cw ? max(rawIn + cr + cw, total - out) : rawIn
        inputTokens = normalizedIn
        cachedInputTokens = cr
        cacheWriteInputTokens = cw
        outputTokens = out
        reasoningOutputTokens = try camel.decodeIfPresent(Int64.self, forKey: .reasoningOutputTokens)
        totalTokens = normalizedIn + out
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(inputTokens, forKey: .inputTokens)
        try container.encode(cachedInputTokens, forKey: .cachedInputTokens)
        try container.encode(cacheWriteInputTokens, forKey: .cacheWriteInputTokens)
        try container.encode(outputTokens, forKey: .outputTokens)
        try container.encodeIfPresent(reasoningOutputTokens, forKey: .reasoningOutputTokens)
        try container.encode(totalTokens, forKey: .totalTokens)
    }

    var cacheHitRate: Double? {
        inputTokens > 0 ? Double(cachedInputTokens) / Double(inputTokens) : nil
    }

    var isValid: Bool {
        let inputAndOutput = inputTokens.addingReportingOverflow(outputTokens)
        let cachedAndWritten = cachedInputTokens.addingReportingOverflow(cacheWriteInputTokens)
        return inputTokens >= 0 && cachedInputTokens >= 0 && cacheWriteInputTokens >= 0
            && outputTokens >= 0 && (reasoningOutputTokens ?? 0) >= 0 && totalTokens >= 0
            && !inputAndOutput.overflow && inputAndOutput.partialValue == totalTokens
            && !cachedAndWritten.overflow && cachedAndWritten.partialValue <= inputTokens
            && (reasoningOutputTokens ?? 0) <= outputTokens
    }

    func adding(_ other: Self) -> Self? {
        let sums = zip(values, other.values).map { $0.addingReportingOverflow($1) }
        guard !sums.contains(where: \.overflow) else { return nil }
        return Self(
            inputTokens: sums[0].partialValue, cachedInputTokens: sums[1].partialValue,
            cacheWriteInputTokens: sums[2].partialValue, outputTokens: sums[3].partialValue,
            reasoningOutputTokens: reasoningOutputTokens != nil && other.reasoningOutputTokens != nil ? sums[4].partialValue : nil, totalTokens: sums[5].partialValue
        )
    }

    private var values: [Int64] {
        [inputTokens, cachedInputTokens, cacheWriteInputTokens, outputTokens, reasoningOutputTokens ?? 0, totalTokens]
    }

    private enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case cachedInputTokens = "cached_input_tokens"
        case cacheWriteInputTokens = "cache_write_input_tokens"
        case outputTokens = "output_tokens"
        case reasoningOutputTokens = "reasoning_output_tokens"
        case totalTokens = "total_tokens"
    }

    private enum CamelCodingKeys: String, CodingKey {
        case inputTokens
        case cachedInputTokens
        case cacheWriteInputTokens
        case outputTokens
        case reasoningOutputTokens
        case totalTokens
    }
}

/// 终态读取可能从文件尾部开始, 使用明确归属的轮次累计值避免漏算前面的响应
nonisolated struct CodexRolloutTokenUsageRecord: Decodable {
    let payload: CodexRolloutTokenUsagePayload
}

nonisolated struct CodexRolloutTokenUsagePayload: Decodable {
    let threadId: String
    let sessionId: String
    let turnId: String
    let rootTurnId: String
    let responseId: String
    let turnTokenUsage: CodexTokenUsage

    private enum CodingKeys: String, CodingKey {
        case threadId = "thread_id"
        case sessionId = "session_id"
        case turnId = "turn_id"
        case rootTurnId = "root_turn_id"
        case responseId = "response_id"
        case turnTokenUsage = "turn_token_usage"
    }
}
