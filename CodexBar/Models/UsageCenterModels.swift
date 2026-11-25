import Foundation

nonisolated enum UsageMenuScope: String, CaseIterable, Identifiable {
    case all = ""
    case codex
    case claude
    case gemini

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .all: "全部"
        case .codex: "Codex"
        case .claude: "Claude"
        case .gemini: "Gemini"
        }
    }

    func includes(_ source: UsageSource) -> Bool {
        guard source.isEnabled else { return false }
        return switch self {
        case .all: source.includesCodex || source.includesClaude || source.includesGemini
        case .codex: source.includesCodex
        case .claude: source.includesClaude
        case .gemini: source.includesGemini
        }
    }
}

nonisolated enum ControlCenterTopologyMode: String, Codable, CaseIterable, Identifiable {
    case localOnly
    case lanDirect
    case remoteHub

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .localOnly: "仅本机模式"
        case .lanDirect: "局域网 / 组网直连"
        case .remoteHub: "自建常驻中枢"
        }
    }

    var subtitle: String {
        switch self {
        case .localOnly: "仅采集当前 Mac, 不开启任何监听端口或外部同步"
        case .lanDirect: "Mac 开启内置局域网接收端; 休眠时各探针本地缓存, 唤醒后自动断点补推"
        case .remoteHub: "所有外部机器单向推送至 24h 常驻中枢, Mac 在线实时同步, 离线唤醒后增量拉取"
        }
    }
}

nonisolated enum ControlCenterSection: String, CaseIterable, Identifiable {
    case usage
    case deployment

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .usage: "用量统计"
        case .deployment: "节点与部署"
        }
    }
}

nonisolated enum UsageTransport: String, Codable, CaseIterable, Identifiable {
    case local
    case probe
    case ssh
    case https

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .local: "本机"
        case .probe: "通用探针"
        case .ssh: "SSH"
        case .https: "HTTPS"
        }
    }
}

nonisolated enum UsageAuthentication: String, Codable, CaseIterable, Identifiable {
    case unknown
    case oauth
    case api

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .unknown: "未知"
        case .oauth: "OAuth"
        case .api: "API"
        }
    }
}

nonisolated struct UsageSource: Codable, Equatable, Identifiable {
    var id = UUID().uuidString
    var name = ""
    var transport = UsageTransport.ssh
    var address = ""
    var codexAuthentication = UsageAuthentication.unknown
    var includesCodex = true
    var includesClaude = false
    var includesGemini = false
    var isEnabled = true
    var codexHome = ""
    var claudeHome = ""
    var geminiHome = ""
    var collectorCacheDirectory: String?
    var bridgeStatusLine = true
    var detectedProviders: [String] = []
    var probeVersion = ""
    var platformName = ""
    var lastSeenAt: Double?
    var isOnline = false

    enum CodingKeys: String, CodingKey {
        case id, name, transport, address, codexAuthentication
        case includesCodex, includesClaude, includesGemini, isEnabled
        case codexHome, claudeHome, geminiHome, collectorCacheDirectory
        case bridgeStatusLine, detectedProviders, probeVersion, platformName, lastSeenAt, isOnline
    }

    init(
        id: String = UUID().uuidString,
        name: String = "",
        transport: UsageTransport = .ssh,
        address: String = "",
        codexAuthentication: UsageAuthentication = .unknown,
        includesCodex: Bool = true,
        includesClaude: Bool = false,
        includesGemini: Bool = false,
        isEnabled: Bool = true,
        codexHome: String = "",
        claudeHome: String = "",
        geminiHome: String = "",
        collectorCacheDirectory: String? = nil,
        bridgeStatusLine: Bool = true,
        detectedProviders: [String] = [],
        probeVersion: String = "",
        platformName: String = "",
        lastSeenAt: Double? = nil,
        isOnline: Bool = false
    ) {
        self.id = id
        self.name = name
        self.transport = transport
        self.address = address
        self.codexAuthentication = codexAuthentication
        self.includesCodex = includesCodex
        self.includesClaude = includesClaude
        self.includesGemini = includesGemini
        self.isEnabled = isEnabled
        self.codexHome = codexHome
        self.claudeHome = claudeHome
        self.geminiHome = geminiHome
        self.collectorCacheDirectory = collectorCacheDirectory
        self.bridgeStatusLine = bridgeStatusLine
        self.detectedProviders = detectedProviders
        self.probeVersion = probeVersion
        self.platformName = platformName
        self.lastSeenAt = lastSeenAt
        self.isOnline = isOnline
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        transport = try container.decodeIfPresent(UsageTransport.self, forKey: .transport) ?? .ssh
        address = try container.decodeIfPresent(String.self, forKey: .address) ?? ""
        codexAuthentication = try container.decodeIfPresent(UsageAuthentication.self, forKey: .codexAuthentication) ?? .unknown
        includesCodex = try container.decodeIfPresent(Bool.self, forKey: .includesCodex) ?? true
        includesClaude = try container.decodeIfPresent(Bool.self, forKey: .includesClaude) ?? false
        includesGemini = try container.decodeIfPresent(Bool.self, forKey: .includesGemini) ?? false
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        codexHome = try container.decodeIfPresent(String.self, forKey: .codexHome) ?? ""
        claudeHome = try container.decodeIfPresent(String.self, forKey: .claudeHome) ?? ""
        geminiHome = try container.decodeIfPresent(String.self, forKey: .geminiHome) ?? ""
        collectorCacheDirectory = try container.decodeIfPresent(String.self, forKey: .collectorCacheDirectory)
        bridgeStatusLine = try container.decodeIfPresent(Bool.self, forKey: .bridgeStatusLine) ?? true
        detectedProviders = try container.decodeIfPresent([String].self, forKey: .detectedProviders) ?? []
        probeVersion = try container.decodeIfPresent(String.self, forKey: .probeVersion) ?? ""
        platformName = try container.decodeIfPresent(String.self, forKey: .platformName) ?? ""
        lastSeenAt = try container.decodeIfPresent(Double.self, forKey: .lastSeenAt)
        isOnline = try container.decodeIfPresent(Bool.self, forKey: .isOnline) ?? false
    }

    static let local = UsageSource(id: "local", name: "本机 Mac", transport: .local, includesClaude: true)

    var enabledProviderNames: [String] {
        [
            includesCodex ? "codex" : nil,
            includesClaude ? "claude" : nil,
            includesGemini ? "gemini" : nil
        ].compactMap(\.self)
    }

    func includesProvider(_ provider: String) -> Bool {
        switch provider {
        case "codex": includesCodex
        case "claude": includesClaude
        case "gemini": includesGemini
        default: false
        }
    }

    var validationError: String? {
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || name.count > 80 {
            return "请输入不超过 80 个字符的节点名称"
        }
        if transport != .probe, !includesCodex, !includesClaude, !includesGemini {
            return "至少启用一个监控渠道"
        }
        if transport == .probe,
           id.range(of: "^[A-Za-z0-9_.-]{1,80}$", options: .regularExpression) == nil {
            return "探针节点标识只允许字母, 数字, 点, 下划线与连字符"
        }
        if transport == .ssh,
           address.range(of: "^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$", options: .regularExpression) == nil {
            return "SSH 地址请填写 ~/.ssh/config 中的主机别名"
        }
        if transport == .https {
            guard let url = URL(string: address), url.scheme == "https", url.host != nil,
                  url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
                  url.path.isEmpty || url.path == "/" else {
                return "请填写 HTTPS 服务根地址, 如 https://stats.example.com:8443"
            }
        }
        for path in [codexHome, claudeHome, geminiHome, collectorCacheDirectory ?? ""] where !path.isEmpty {
            if !path.hasPrefix("/"), !path.hasPrefix("~/") {
                return "数据目录需要使用绝对路径或 ~/ 开头的路径"
            }
            if path.count > 1024 || path.contains("\n") || path.contains("\0") {
                return "数据目录格式无效"
            }
        }
        return nil
    }
}

nonisolated struct UsageRecord: Codable {
    let id: String
    let provider: String
    let auth: String
    let day: String
    let session: String
    let model: String
    let project: String
    let kind: String
    let state: String
    let observedAt: Double
    let input: Int64
    let output: Int64
    let cacheRead: Int64
    let cacheWrite: Int64
    let reasoning: Int64
    let turns: Int64
    let tools: Int64
    let permissions: Int64
    let compactions: Int64
    let subagents: Int64
    let durationMs: Int64
    var nodeId: String?

    var isValid: Bool {
        let counters = [input, output, cacheRead, cacheWrite, reasoning, turns, tools, permissions, compactions, subagents, durationMs]
        return id.count == 64 && session.count == 64
            && ["codex", "claude", "gemini"].contains(provider)
            && UsageAuthentication(rawValue: auth) != nil
            && day.range(of: "^20[0-9]{2}-[01][0-9]-[0-3][0-9]$", options: .regularExpression) != nil
            && model.count <= 120 && project.count <= 120 && kind.count <= 30 && state.count <= 30
            && observedAt.isFinite && observedAt > 0 && observedAt < Date().timeIntervalSince1970 + 86400
            && counters.allSatisfy { $0 >= 0 && $0 <= 1000000000000 }
    }

    var totalTokens: Int64 {
        input + output + (["claude", "gemini"].contains(provider) ? cacheRead + cacheWrite : 0)
    }
}

nonisolated struct UsageQuotaObservation: Codable, Identifiable, Equatable {
    struct Window: Codable, Identifiable, Equatable {
        let name: String
        let usedPercent: Double
        let resetsAt: Double?
        var id: String {
            name
        }
    }

    let provider: String
    let observedAt: Double
    let windows: [Window]
    var id: String {
        provider
    }

    var isValid: Bool {
        ["codex", "claude", "gemini"].contains(provider) && observedAt.isFinite && observedAt > 0
            && windows.count <= 10 && windows.allSatisfy {
                $0.name.count <= 40 && $0.usedPercent.isFinite && (0 ... 100).contains($0.usedPercent)
                    && ($0.resetsAt == nil || ($0.resetsAt?.isFinite == true && $0.resetsAt! > 0))
            }
    }

    func isPreferred(over other: UsageQuotaObservation, at now: Double) -> Bool {
        if ["claude", "gemini"].contains(provider), other.provider == provider {
            let complete = hasCurrentFiveHourReset(at: now)
            let otherComplete = other.hasCurrentFiveHourReset(at: now)
            if complete != otherComplete {
                return complete
            }
            if complete {
                // 状态栏重绘可能重报旧缓存, 同等完整的记录先按额度窗口排序
                for name in ["5h", "7d"] {
                    let reset = windows.first { $0.name == name }?.resetsAt ?? 0
                    let otherReset = other.windows.first { $0.name == name }?.resetsAt ?? 0
                    if reset != otherReset {
                        return reset > otherReset
                    }
                }
            }
            let evidence = fiveHourEvidenceTime(at: now)
            let otherEvidence = other.fiveHourEvidenceTime(at: now)
            if evidence != otherEvidence {
                return evidence > otherEvidence
            }
        }
        return observedAt > other.observedAt
    }

    private func hasCurrentFiveHourReset(at now: Double) -> Bool {
        let age = now - observedAt
        return age >= 0 && age < 5 * 3600 && (windows.first { $0.name == "5h" }?.resetsAt ?? 0) > now
    }

    private func fiveHourEvidenceTime(at now: Double) -> Double {
        guard let reset = windows.first(where: { $0.name == "5h" })?.resetsAt, reset > 0, reset <= now else { return observedAt }
        // 窗口结束是明确证据, 不能被结束前的无时间缓存替换
        return max(observedAt, reset)
    }
}

nonisolated struct UsageEnvelope: Decodable {
    let `protocol`: Int
    let epoch: String
    let cursor: Int64
    let reset: Bool
    let hasMore: Bool
    let generatedAt: Double
    let records: [UsageRecord]
    let warnings: [String]
    let quotas: [UsageQuotaObservation]
    let retentionDays: Int
    let scanComplete: Bool?
    let currentCodexAuthentication: UsageAuthentication?
    let geminiPlan: String?

    var isValid: Bool {
        `protocol` == 1 && UUID(uuidString: epoch) != nil && cursor >= 0 && records.count <= 3000
            && generatedAt.isFinite && generatedAt >= 0 && retentionDays == 210
            && records.allSatisfy(\.isValid) && quotas.count <= 3 && quotas.allSatisfy(\.isValid)
            && warnings.count <= 30 && warnings.allSatisfy { $0.count <= 300 }
            && (geminiPlan == nil || (geminiPlan?.count ?? 0) <= 40)
    }
}

nonisolated struct UsageCursor {
    var epoch = ""
    var revision: Int64 = 0
}

nonisolated enum UsageGrouping: String, CaseIterable, Identifiable {
    case machine = "机器"
    case provider = "工具"
    case authentication = "登录方式"
    case model = "模型"
    case project = "项目"

    var id: String {
        rawValue
    }
}

nonisolated struct UsageFilter: Hashable {
    var sourceID = ""
    var provider = ""
    var authentication = ""
    var days = 30
    var grouping = UsageGrouping.model
    var localOnly = false
}

nonisolated struct UsageMetrics: Equatable {
    var tokens: Int64 = 0
    var input: Int64 = 0
    var output: Int64 = 0
    var cacheRead: Int64 = 0
    var cacheWrite: Int64 = 0
    var sessions: Int64 = 0
    var turns: Int64 = 0
    var tools: Int64 = 0
    var permissions: Int64 = 0
    var compactions: Int64 = 0
    var subagents: Int64 = 0
    var durationMs: Int64 = 0
    var interruptions: Int64?
}

nonisolated struct UsageGroup: Identifiable {
    let name: String
    let metrics: UsageMetrics
    var id: String {
        name
    }
}

nonisolated struct UsageDay: Identifiable, Equatable {
    let day: String
    let tokens: Int64
    var metrics: UsageMetrics?
    var topModel: String?
    var longestTurnMs: Int64?
    var modelTokens: [String: Int64] = [:]
    var id: String {
        day
    }
}

nonisolated struct UsageActivity: Identifiable {
    let id: String
    let machine: String
    let provider: String
    let project: String
    let model: String
    let state: String
    let observedAt: Double
}

nonisolated struct UsageDashboard {
    var totals = UsageMetrics()
    var groups: [UsageGroup] = []
    var days: [UsageDay] = []
    var activities: [UsageActivity] = []

    var longestTurnMs: Int64? {
        days.compactMap(\.longestTurnMs).max()
    }

    func streaks(now: Date = Date()) -> (current: Int, longest: Int) {
        let formatter = ISO8601DateFormatter()
        let today = String(formatter.string(from: now).prefix(10))
        let activeDays = Set(days.filter { $0.day <= today && ($0.tokens > 0 || ($0.metrics?.turns ?? 0) > 0) }.map(\.day))
        func key(_ date: Date) -> String {
            String(formatter.string(from: date).prefix(10))
        }
        var current = 0
        var date = activeDays.contains(key(now)) ? now : now.addingTimeInterval(-86400)
        while activeDays.contains(key(date)) {
            current += 1
            date = date.addingTimeInterval(-86400)
        }
        var longest = 0
        var run = 0
        var previous: Date?
        for day in activeDays.sorted() {
            guard let date = formatter.date(from: day + "T00:00:00Z") else { continue }
            run = previous.map { date.timeIntervalSince($0) == 86400 } == true ? run + 1 : 1
            longest = max(longest, run)
            previous = date
        }
        return (current, longest)
    }

    func tokenCount(lastDays: Int, now: Date = Date()) -> Int64 {
        let formatter = ISO8601DateFormatter()
        let start = String(formatter.string(from: now.addingTimeInterval(-Double(max(0, lastDays - 1)) * 86400)).prefix(10))
        let end = String(formatter.string(from: now).prefix(10))
        return days.filter { $0.day >= start && $0.day <= end }.reduce(0) { $0 + $1.tokens }
    }
}

nonisolated struct UsageSourceStatus {
    var lastSuccess: Date?
    var error: String?
    var warnings: [String] = []
    var quotas: [UsageQuotaObservation] = []
    var currentCodexAuthentication: UsageAuthentication?
    var geminiPlan: String?
}
