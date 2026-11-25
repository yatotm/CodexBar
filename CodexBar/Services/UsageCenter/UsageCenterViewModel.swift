import AppKit
import Combine
import Foundation

@MainActor
final class UsageCenterViewModel: ObservableObject {
    @Published private(set) var sources: [UsageSource] = [] {
        didSet {
            analytics.history.setSources(sources)
            remoteActivity.setSources(sources)
            reconcileMenuScope()
        }
    }

    @Published var activeSection = ControlCenterSection.usage
    @Published var topologyMode: ControlCenterTopologyMode = {
        let raw = UserDefaults.standard.string(forKey: "ControlCenter.topologyMode") ?? ""
        return ControlCenterTopologyMode(rawValue: raw) ?? .localOnly
    }() {
        didSet {
            guard topologyMode != oldValue else { return }
            UserDefaults.standard.set(topologyMode.rawValue, forKey: "ControlCenter.topologyMode")
            filter.localOnly = (topologyMode == .localOnly)
            reconcileMenuScope()
            reloadDashboard()
            reloadMenuDashboards()
            restartTopologyLoops()
        }
    }

    @Published var remoteHubURL: String = UserDefaults.standard.string(forKey: "ControlCenter.remoteHubURL") ?? "" {
        didSet {
            UserDefaults.standard.set(remoteHubURL, forKey: "ControlCenter.remoteHubURL")
        }
    }

    @Published var lanPort: Int = {
        let saved = UserDefaults.standard.integer(forKey: "ControlCenter.lanPort")
        return (1024 ... 65535).contains(saved) ? saved : 18765
    }() {
        didSet {
            UserDefaults.standard.set(lanPort, forKey: "ControlCenter.lanPort")
        }
    }

    @Published private(set) var statuses: [String: UsageSourceStatus] = [:]
    @Published private(set) var dashboard = UsageDashboard()
    @Published private(set) var dashboardFilter: UsageFilter?
    @Published private(set) var menuDashboards: [UsageMenuScope: UsageDashboard] = [:]
    @Published var menuScope = UsageMenuScope.all
    @Published private(set) var isRefreshing = false
    @Published private(set) var refreshingSource = ""
    @Published private(set) var hubHealthy: Bool?
    @Published private(set) var hubStatusText = "未启用外部中枢"
    @Published private(set) var geminiPeriods: [GeminiValuationPeriod] = []
    @Published private(set) var claudePeriods: [GeminiValuationPeriod] = []
    @Published var error: String?
    @Published var filter = UsageFilter() {
        didSet {
            if filter != oldValue {
                reloadDashboard()
            }
        }
    }

    @Published var automaticRefresh = UserDefaults.standard.object(forKey: "UsageCenter.automaticRefresh") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(automaticRefresh, forKey: "UsageCenter.automaticRefresh")
            scheduleRefresh()
        }
    }

    let analytics = UsageAnalyticsViewModel()
    let remoteActivity = RemoteActivityController()
    let geminiPriceBook = GeminiPriceBook.loadBundled()
    private let store = UsageCenterStore()
    private let client = UsageCollectorClient()
    private let hubClient = HubSyncClient()
    private var refreshTask: Task<Void, Never>?
    private var timerTask: Task<Void, Never>?
    private var dashboardTask: Task<Void, Never>?
    private var menuDashboardTask: Task<Void, Never>?
    private var hubEventTask: Task<Void, Never>?
    private var localLiveTask: Task<Void, Never>?
    private var localGeminiEvidence = GeminiValuationEvidence.empty
    private var hubGeminiEvidence = GeminiValuationEvidence.empty
    private var localClaudeEvidence = GeminiValuationEvidence.empty
    private var hubClaudeEvidence = GeminiValuationEvidence.empty
    private var valuationTask: Task<Void, Never>?
    private var hubLiveRevision: Int64 = 0
    private var failures: [String: Int] = [:]
    private var nextAttempts: [String: Date] = [:]
    private var isSleeping = false

    var effectiveSources: [UsageSource] {
        topologyMode == .localOnly ? sources.filter { $0.id == "local" } : sources
    }

    var activeProviders: [UsageMenuScope] {
        [.codex, .claude, .gemini].filter { scope in
            effectiveSources.contains { scope.includes($0) }
        }
    }

    var visibleMenuScopes: [UsageMenuScope] {
        let providers = activeProviders
        if providers.isEmpty {
            return [.codex]
        }
        if providers.count == 1, let single = providers.first {
            if single == .codex, effectiveSources.filter({ $0.isEnabled && $0.includesCodex }).count > 1 {
                return [.all, .codex]
            }
            return [single]
        }
        return [.all] + providers
    }

    var menuSources: [UsageSource] {
        effectiveSources.filter(menuScope.includes)
    }

    var menuDashboard: UsageDashboard? {
        menuDashboards[menuScope]
    }

    var latestClaudeQuota: UsageQuotaObservation? {
        latestQuota(for: "claude", scope: .claude)
    }

    var latestGeminiQuota: UsageQuotaObservation? {
        latestQuota(for: "gemini", scope: .gemini)
    }

    var latestGeminiPlan: String? {
        for source in effectiveSources where UsageMenuScope.gemini.includes(source) {
            if let plan = statuses[source.id]?.geminiPlan, !plan.isEmpty {
                return plan
            }
        }
        return geminiPeriods.first?.planTitle
    }

    var hasOfflineGeminiNodes: Bool {
        guard topologyMode != .localOnly else { return false }
        return effectiveSources.contains { $0.id != "local" && $0.isEnabled && $0.includesGemini && !$0.isOnline }
    }

    var hasOfflineClaudeNodes: Bool {
        guard topologyMode != .localOnly else { return false }
        return effectiveSources.contains { $0.id != "local" && $0.isEnabled && $0.includesClaude && !$0.isOnline }
    }

    func isProviderEnabledAnywhere(_ scope: UsageMenuScope) -> Bool {
        activeProviders.contains(scope)
    }

    func start() {
        filter.localOnly = (topologyMode == .localOnly)
        Task { [weak self] in
            guard let self else { return }
            do {
                try await bootstrapInitialSources()
                for source in sources {
                    statuses[source.id] = try await store.status(for: source)
                }
                if let rawVal = try await store.hubValue(forKey: "geminiValuation"),
                   let decoded = try? JSONDecoder().decode(GeminiValuationEvidence.self, from: Data(rawVal.utf8)) {
                    hubGeminiEvidence = decoded
                }
                if let rawCVal = try await store.hubValue(forKey: "claudeValuation"),
                   let decodedC = try? JSONDecoder().decode(GeminiValuationEvidence.self, from: Data(rawCVal.utf8)) {
                    hubClaudeEvidence = decodedC
                }
                recalculateGeminiValuation()
                reloadDashboard()
                reloadMenuDashboards()
                restartTopologyLoops()
                if automaticRefresh {
                    refresh(manual: false)
                }
                scheduleRefresh()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func bootstrapInitialSources() async throws {
        var loaded = try await store.sources()
        let agyBrainExists = FileManager.default.fileExists(
            atPath: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".gemini/antigravity-cli/brain").path
        )
        let migratedGeminiKey = "ControlCenter.didBootstrapLocalGemini"
        if loaded.isEmpty {
            var initialLocal = UsageSource.local
            initialLocal.includesGemini = agyBrainExists
            UserDefaults.standard.set(true, forKey: migratedGeminiKey)
            try await store.save(initialLocal)
            loaded = [initialLocal]
        } else if !UserDefaults.standard.bool(forKey: migratedGeminiKey) {
            UserDefaults.standard.set(true, forKey: migratedGeminiKey)
            if agyBrainExists, let idx = loaded.firstIndex(where: { $0.id == "local" }), !loaded[idx].includesGemini {
                loaded[idx].includesGemini = true
                try await store.save(loaded[idx])
            }
            if UserDefaults.standard.object(forKey: "ControlCenter.topologyMode") == nil,
               loaded.contains(where: { $0.id != "local" && $0.isEnabled }) {
                topologyMode = .remoteHub
            }
        }
        sources = loaded
        if let local = loaded.first(where: { $0.id == "local" }), local.bridgeStatusLine {
            await reconcileLocalBridges(for: local)
        }
    }

    func stop() {
        remoteActivity.stop()
        refreshTask?.cancel()
        timerTask?.cancel()
        dashboardTask?.cancel()
        menuDashboardTask?.cancel()
        hubEventTask?.cancel()
        localLiveTask?.cancel()
        Task { await hubClient.stopLanHub() }
        analytics.stop()
    }

    func pauseForSleep() {
        guard !isSleeping else { return }
        isSleeping = true
        cancelRefresh()
        timerTask?.cancel()
        timerTask = nil
        hubEventTask?.cancel()
        hubEventTask = nil
        localLiveTask?.cancel()
        localLiveTask = nil
        Task { await hubClient.stopLanHub() }
        analytics.pauseForSleep()
    }

    func resumeAfterWake() {
        guard isSleeping else { return }
        isSleeping = false
        restartTopologyLoops()
        refresh(manual: false)
        scheduleRefresh()
        analytics.resumeAfterWake()
    }

    func refresh(manual: Bool = true) {
        guard refreshTask == nil, !isRefreshing, !isSleeping else { return }
        isRefreshing = true
        error = nil
        refreshTask = Task { [weak self] in
            guard let self else { return }
            defer {
                isRefreshing = false
                refreshingSource = ""
                refreshTask = nil
                recalculateGeminiValuation()
                reloadDashboard()
                reloadMenuDashboards()
            }
            do {
                sources = try await store.sources()
            } catch {
                self.error = error.localizedDescription
                return
            }
            if topologyMode != .localOnly {
                await refreshHubIfConfigured()
            }
            await refreshDirectSources(manual: manual)
        }
    }

    private func refreshDirectSources(manual: Bool) async {
        let candidates = effectiveSources.filter { $0.isEnabled && $0.transport != .probe }
        for source in candidates {
            if Task.isCancelled {
                break
            }
            if !manual, let next = nextAttempts[source.id], next > Date() {
                continue
            }
            refreshingSource = source.name
            do {
                try await refreshSingleSource(source)
                failures[source.id] = 0
                nextAttempts[source.id] = nil
            } catch is CancellationError {
                break
            } catch {
                var status = statuses[source.id] ?? UsageSourceStatus()
                status.error = error.localizedDescription
                statuses[source.id] = status
                let count = min(6, (failures[source.id] ?? 0) + 1)
                failures[source.id] = count
                nextAttempts[source.id] = Date().addingTimeInterval(min(3600, 300 * pow(2, Double(count - 1))))
            }
        }
    }

    private func refreshSingleSource(_ source: UsageSource) async throws {
        var cursor = try await store.cursor(for: source)
        let deadline = ContinuousClock.now.advanced(by: .seconds(60))
        var scan = true
        for _ in 0 ..< 40 {
            try Task.checkCancellation()
            let response = try await client.fetch(source: source, cursor: cursor, scan: scan)
            try Task.checkCancellation()
            try await store.apply(response, source: source)
            cursor = UsageCursor(epoch: response.epoch, revision: response.cursor)
            statuses[source.id] = try await store.status(for: source)
            statuses[source.id]?.currentCodexAuthentication = response.currentCodexAuthentication
            if source.transport == .local {
                if source.includesGemini, let val = try? await client.fetchLocalGeminiValuation(source: source, scan: false) {
                    localGeminiEvidence = val
                }
                if source.includesClaude, let cval = try? await client.fetchLocalClaudeValuation(source: source) {
                    localClaudeEvidence = cval
                }
            }
            if !response.hasMore {
                if response.scanComplete != false || source.transport == .https || source.collectorCacheDirectory != nil {
                    return
                }
                scan = true
            } else {
                scan = false
            }
            if ContinuousClock.now >= deadline {
                break
            }
        }
        statuses[source.id]?.warnings.append("历史数据仍在回填, 下次刷新继续")
    }

    private struct ActiveHubEndpoint {
        let url: String
        let token: String
        let allowHTTP: Bool
    }

    private func activeHubEndpoint() async throws -> ActiveHubEndpoint? {
        switch topologyMode {
        case .localOnly:
            return nil
        case .lanDirect:
            let token = try await hubClient.startLanHubIfNeeded(port: lanPort)
            return ActiveHubEndpoint(url: "http://127.0.0.1:\(lanPort)", token: token, allowHTTP: true)
        case .remoteHub:
            let trimmed = remoteHubURL.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            guard let token = await hubClient.loadSecret(account: "remote-hub", isNodeToken: false), !token.isEmpty else {
                throw UsageCenterError(message: "请在节点与部署页填写常驻中枢读取密钥")
            }
            return ActiveHubEndpoint(url: trimmed, token: token, allowHTTP: false)
        }
    }

    private func refreshHubIfConfigured() async {
        do {
            guard let endpoint = try await activeHubEndpoint() else {
                hubHealthy = nil
                hubStatusText = topologyMode == .localOnly ? "未启用外部中枢" : "待填写中枢地址"
                return
            }
            refreshingSource = topologyMode == .lanDirect ? "局域网接收端" : "常驻中枢"
            var cursor = try await store.hubCursor()
            for _ in 0 ..< 25 {
                try Task.checkCancellation()
                let pulled = try await hubClient.pull(
                    hubURL: endpoint.url,
                    readToken: endpoint.token,
                    epoch: cursor.epoch,
                    cursor: cursor.revision,
                    allowHTTP: endpoint.allowHTTP
                )
                hubLiveRevision = max(hubLiveRevision, pulled.liveRevision)
                try await applyPulledHubData(pulled)
                cursor = UsageCursor(epoch: pulled.epoch, revision: pulled.cursor)
                if !pulled.hasMore {
                    break
                }
            }
            hubHealthy = true
            hubStatusText = topologyMode == .lanDirect ? "本机接收端运行中 (:\(lanPort))" : "中枢已连接 · 实时同步"
        } catch is CancellationError {
            return
        } catch {
            hubHealthy = false
            hubStatusText = error.localizedDescription
            self.error = error.localizedDescription
        }
    }

    private func applyPulledHubData(_ pulled: HubPullResponse) async throws {
        let existingByID = Dictionary(uniqueKeysWithValues: sources.map { ($0.id, $0) })
        var mappedNodes: [UsageSource] = []
        var mappedStatuses: [String: UsageSourceStatus] = [:]
        for remote in pulled.nodes {
            var source = existingByID[remote.id] ?? UsageSource(id: remote.id, name: remote.name, transport: .probe)
            source.transport = .probe
            source.name = remote.name.isEmpty ? source.name : remote.name
            source.isEnabled = remote.enabled
            source.includesCodex = remote.enabledProviders.contains("codex")
            source.includesClaude = remote.enabledProviders.contains("claude")
            source.includesGemini = remote.enabledProviders.contains("gemini")
            source.bridgeStatusLine = remote.bridgeStatusLine
            source.detectedProviders = remote.detectedProviders
            source.probeVersion = remote.probeVersion
            source.platformName = remote.platform
            source.lastSeenAt = remote.lastSeenAt
            source.isOnline = remote.online
            mappedNodes.append(source)
            mappedStatuses[remote.id] = UsageSourceStatus(
                lastSuccess: remote.lastSeenAt.map { Date(timeIntervalSince1970: $0) },
                warnings: remote.warnings,
                quotas: remote.quotas,
                currentCodexAuthentication: remote.currentCodexAuthentication,
                geminiPlan: remote.geminiPlan
            )
        }
        try await store.applyHubBatch(
            epoch: pulled.epoch,
            cursor: pulled.cursor,
            reset: pulled.reset,
            generatedAt: pulled.generatedAt,
            nodes: mappedNodes,
            nodeStatuses: mappedStatuses,
            records: pulled.records
        )
        if let gval = pulled.geminiValuation {
            hubGeminiEvidence = gval
            if let encoded = try? String(data: JSONEncoder().encode(gval), encoding: .utf8) {
                try? await store.saveHubValue(encoded, forKey: "geminiValuation")
            }
        }
        if let cval = pulled.claudeValuation {
            hubClaudeEvidence = cval
            if let encoded = try? String(data: JSONEncoder().encode(cval), encoding: .utf8) {
                try? await store.saveHubValue(encoded, forKey: "claudeValuation")
            }
        }
        sources = try await store.sources()
        for node in mappedNodes {
            statuses[node.id] = mappedStatuses[node.id]
            let nodeTasks = pulled.liveTasks[node.id] ?? []
            remoteActivity.applyProbeSnapshot(
                sourceID: node.id,
                tasks: nodeTasks,
                isOnline: node.isOnline,
                emitLiveNotifications: true
            )
        }
        remoteActivity.clearProbeSnapshots(keeping: Set(mappedNodes.map(\.id)))
    }

    private func restartTopologyLoops() {
        hubEventTask?.cancel()
        hubEventTask = nil
        localLiveTask?.cancel()
        localLiveTask = nil
        guard !isSleeping else { return }

        localLiveTask = Task { [weak self] in
            while !Task.isCancelled {
                if let self, let local = sources.first(where: { $0.id == "local" }),
                   local.isEnabled, local.includesClaude || local.includesGemini,
                   let snapshot = try? await client.fetchLocalZeroHookSnapshot(source: local) {
                    remoteActivity.applyProbeSnapshot(
                        sourceID: "local",
                        tasks: snapshot.tasks,
                        isOnline: true,
                        emitLiveNotifications: true
                    )
                    applyLocalLiveQuotas(snapshot.quotas)
                }
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
            }
        }

        guard topologyMode != .localOnly else {
            Task { await hubClient.stopLanHub() }
            hubHealthy = nil
            hubStatusText = "未启用外部中枢"
            return
        }

        hubEventTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                do {
                    guard let endpoint = try await activeHubEndpoint() else {
                        try await Task.sleep(for: .seconds(5))
                        continue
                    }
                    let events = try await hubClient.waitEvents(
                        hubURL: endpoint.url,
                        readToken: endpoint.token,
                        revision: hubLiveRevision,
                        allowHTTP: endpoint.allowHTTP
                    )
                    guard !Task.isCancelled else { return }
                    if events.liveRevision > hubLiveRevision {
                        hubLiveRevision = events.liveRevision
                        applyLiveEventFrame(events)
                    }
                } catch is CancellationError {
                    return
                } catch {
                    do { try await Task.sleep(for: .seconds(5)) } catch { return }
                }
            }
        }
    }

    private func applyLocalLiveQuotas(_ liveQuotas: [UsageQuotaObservation]) {
        guard !liveQuotas.isEmpty else { return }
        var st = statuses["local"] ?? UsageSourceStatus()
        var byProvider = Dictionary(uniqueKeysWithValues: st.quotas.map { ($0.provider, $0) })
        let now = Date().timeIntervalSince1970
        var changed = false
        for q in liveQuotas where q.isValid {
            if let existing = byProvider[q.provider] {
                if q.isPreferred(over: existing, at: now), q != existing {
                    byProvider[q.provider] = q
                    changed = true
                }
            } else {
                byProvider[q.provider] = q
                changed = true
            }
        }
        if changed {
            st.quotas = Array(byProvider.values)
            statuses["local"] = st
            recalculateGeminiValuation()
        }
    }

    private func applyLiveEventFrame(_ events: HubEventsResponse) {
        hubHealthy = true
        for remote in events.nodes {
            var st = statuses[remote.id] ?? UsageSourceStatus()
            st.lastSuccess = remote.lastSeenAt.map { Date(timeIntervalSince1970: $0) } ?? st.lastSuccess
            st.quotas = remote.quotas
            st.warnings = remote.warnings
            st.geminiPlan = remote.geminiPlan ?? st.geminiPlan
            statuses[remote.id] = st
            if let idx = sources.firstIndex(where: { $0.id == remote.id }) {
                sources[idx].isOnline = remote.online
                sources[idx].lastSeenAt = remote.lastSeenAt
                sources[idx].detectedProviders = remote.detectedProviders
            }
            remoteActivity.applyProbeSnapshot(
                sourceID: remote.id,
                tasks: events.liveTasks[remote.id] ?? [],
                isOnline: remote.online,
                emitLiveNotifications: true
            )
        }
        recalculateGeminiValuation()
    }

    func saveHubSettings(mode: ControlCenterTopologyMode, hubURL: String, readToken: String, port: Int) async -> Bool {
        error = nil
        do {
            if !readToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                try await hubClient.saveSecret(readToken, account: "remote-hub", isNodeToken: false)
            }
            lanPort = port
            remoteHubURL = hubURL.trimmingCharacters(in: .whitespacesAndNewlines)
            if topologyMode != mode {
                topologyMode = mode
            } else {
                restartTopologyLoops()
            }
            refresh(manual: true)
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    func upsertProbeNode(
        nodeID: String,
        name: String,
        includesCodex: Bool,
        includesClaude: Bool,
        includesGemini: Bool,
        bridgeStatusLine: Bool,
        rotateToken: Bool
    ) async throws -> String {
        guard let endpoint = try await activeHubEndpoint() else {
            throw UsageCenterError(message: "请先切换到局域网直连或自建常驻中枢模式")
        }
        let cleanID = nodeID.trimmingCharacters(in: .whitespacesAndNewlines)
        var rawWriteToken = await hubClient.loadSecret(account: cleanID, isNodeToken: true) ?? ""
        var signingKey: String?
        if rotateToken || rawWriteToken.isEmpty {
            rawWriteToken = HubCrypto.randomToken(prefix: "cbw_")
            try await hubClient.saveSecret(rawWriteToken, account: cleanID, isNodeToken: true)
            signingKey = HubCrypto.deriveSigningKey(rawWriteToken: rawWriteToken)
        }
        let existing = sources.first { $0.id == cleanID }
        var source = existing ?? UsageSource(id: cleanID, name: name, transport: .probe)
        source.transport = .probe
        source.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        source.isEnabled = existing?.isEnabled ?? true
        source.includesCodex = includesCodex
        source.includesClaude = includesClaude
        source.includesGemini = includesGemini
        source.bridgeStatusLine = bridgeStatusLine
        if let validation = source.validationError {
            throw UsageCenterError(message: validation)
        }
        try await hubClient.upsertNode(
            hubURL: endpoint.url,
            readToken: endpoint.token,
            source: source,
            signingKey: signingKey,
            allowHTTP: endpoint.allowHTTP
        )
        try await store.save(source)
        sources = try await store.sources()
        reloadDashboard()
        reloadMenuDashboards()
        return await installCommand(for: source) ?? ""
    }

    func installCommand(for source: UsageSource) async -> String? {
        guard source.transport == .probe else { return nil }
        guard let rawToken = await hubClient.loadSecret(account: source.id, isNodeToken: true), !rawToken.isEmpty else {
            return nil
        }
        let externalURL: String
        switch topologyMode {
        case .remoteHub:
            externalURL = remoteHubURL
        case .lanDirect:
            let ip = HubCrypto.localIPv4Addresses().first ?? "127.0.0.1"
            externalURL = "http://\(ip):\(lanPort)"
        case .localOnly:
            return nil
        }
        guard !externalURL.isEmpty else { return nil }
        return HubCrypto.probeInstallCommand(
            hubURL: externalURL,
            nodeID: source.id,
            rawWriteToken: rawToken,
            providers: source.enabledProviderNames,
            bridgeStatusLine: source.bridgeStatusLine
        )
    }

    func setChannel(_ provider: UsageMenuScope, enabled: Bool, for source: UsageSource) async {
        var updated = source
        switch provider {
        case .codex: updated.includesCodex = enabled
        case .claude: updated.includesClaude = enabled
        case .gemini: updated.includesGemini = enabled
        case .all: return
        }
        if updated.transport != .probe, !updated.includesCodex, !updated.includesClaude, !updated.includesGemini {
            error = "本机或传统来源至少保留一个开启的监控渠道; 若需停用可关闭节点总开关"
            return
        }
        await applySourceMutation(updated)
    }

    func setSourceEnabled(_ enabled: Bool, for source: UsageSource) async {
        var updated = source
        updated.isEnabled = enabled
        await applySourceMutation(updated)
    }

    func setBridgeStatusLine(_ enabled: Bool, for source: UsageSource) async {
        var updated = source
        updated.bridgeStatusLine = enabled
        await applySourceMutation(updated)
    }

    private func applySourceMutation(_ updated: UsageSource) async {
        do {
            try await store.save(updated)
            sources = try await store.sources()
            if updated.transport == .local {
                await reconcileLocalBridges(for: updated)
            } else if updated.transport == .probe, let endpoint = try await activeHubEndpoint() {
                try await hubClient.upsertNode(
                    hubURL: endpoint.url,
                    readToken: endpoint.token,
                    source: updated,
                    signingKey: nil,
                    allowHTTP: endpoint.allowHTTP
                )
            }
            recalculateGeminiValuation()
            reloadDashboard()
            reloadMenuDashboards()
            if updated.transport == .local, updated.isEnabled {
                refresh(manual: true)
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func reconcileLocalBridges(for local: UsageSource) async {
        if local.includesClaude {
            try? await client.configureClaude(source: local, install: local.bridgeStatusLine && local.isEnabled, includeHooks: false)
        } else {
            try? await client.configureClaude(source: local, install: false, includeHooks: false)
        }
        if local.includesGemini {
            try? await client.configureGemini(source: local, install: local.bridgeStatusLine && local.isEnabled)
        } else {
            try? await client.configureGemini(source: local, install: false)
        }
    }

    func cancelRefresh() {
        refreshTask?.cancel()
    }

    func configureClaude(source: UsageSource, install: Bool) async -> Bool {
        guard !isRefreshing else { return false }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            try await client.configureClaude(source: source, install: install, includeHooks: false)
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    func save(_ source: UsageSource, token: String) async -> Bool {
        guard !isRefreshing else { return false }
        do {
            if let validation = source.validationError {
                throw UsageCenterError(message: validation)
            }
            try await client.saveToken(token, for: source.id)
            try await store.save(source)
            sources = try await store.sources()
            if source.transport == .local {
                await reconcileLocalBridges(for: source)
            }
            reloadDashboard()
            reloadMenuDashboards()
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    func remove(_ source: UsageSource) async {
        guard !isRefreshing, source.id != "local" else { return }
        do {
            if source.transport == .probe, let endpoint = try? await activeHubEndpoint() {
                try? await hubClient.deleteNode(hubURL: endpoint.url, readToken: endpoint.token, nodeID: source.id, allowHTTP: endpoint.allowHTTP)
            }
            await hubClient.deleteSecret(account: source.id, isNodeToken: true)
            try await store.remove(source)
            remoteActivity.setEnabled(false, sourceID: source.id)
            remoteActivity.clearProbeSnapshots(keeping: Set(sources.filter { $0.id != source.id }.map(\.id)))
            await client.deleteToken(for: source.id)
            sources = try await store.sources()
            statuses[source.id] = nil
            if filter.sourceID == source.id {
                filter.sourceID = ""
            }
            recalculateGeminiValuation()
            reloadDashboard()
            reloadMenuDashboards()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func reconcileMenuScope() {
        let allowed = visibleMenuScopes
        if !allowed.contains(menuScope) {
            menuScope = allowed.first ?? .codex
        }
        if !filter.provider.isEmpty,
           let filterScope = UsageMenuScope(rawValue: filter.provider),
           !activeProviders.contains(filterScope) {
            filter.provider = ""
        }
    }

    private func latestQuota(for provider: String, scope: UsageMenuScope) -> UsageQuotaObservation? {
        var latest: UsageQuotaObservation?
        let now = Date().timeIntervalSince1970
        for source in effectiveSources where scope.includes(source) {
            for quota in statuses[source.id]?.quotas ?? [] where quota.provider == provider {
                if latest.map({ quota.isPreferred(over: $0, at: now) }) ?? true {
                    latest = quota
                }
            }
        }
        return latest
    }

    private func recalculateGeminiValuation() {
        valuationTask?.cancel()
        let localOnly = (topologyMode == .localOnly)
        let localSource = sources.first { $0.id == "local" }
        let gEvidences = (localSource?.isEnabled == true && localSource?.includesGemini == true ? [localGeminiEvidence] : [])
            + (localOnly ? [] : [hubGeminiEvidence])
        let cEvidences = (localSource?.isEnabled == true && localSource?.includesClaude == true ? [localClaudeEvidence] : [])
            + (localOnly ? [] : [hubClaudeEvidence])
        let liveG = latestGeminiQuota
        let liveC = latestClaudeQuota
        let book = geminiPriceBook

        valuationTask = Task { [weak self] in
            guard let self else { return }
            let gRecords = await (try? store.valuationUsageRecords(provider: "gemini", localOnly: localOnly)) ?? []
            let cRecords = await (try? store.valuationUsageRecords(provider: "claude", localOnly: localOnly)) ?? []
            guard !Task.isCancelled else { return }
            geminiPeriods = GeminiValuationCalculator.computePeriods(
                provider: "gemini",
                evidences: gEvidences,
                storeRecords: gRecords,
                liveWeeklyObservation: liveG,
                priceBook: book
            )
            claudePeriods = GeminiValuationCalculator.computePeriods(
                provider: "claude",
                evidences: cEvidences,
                storeRecords: cRecords,
                liveWeeklyObservation: liveC,
                priceBook: book
            )
        }
    }

    private func reloadDashboard() {
        dashboardTask?.cancel()
        var requestedFilter = filter
        requestedFilter.localOnly = (topologyMode == .localOnly)
        dashboardTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await store.dashboard(filter: requestedFilter)
                guard !Task.isCancelled else { return }
                dashboard = result
                dashboardFilter = filter
            } catch {
                if !Task.isCancelled {
                    self.error = error.localizedDescription
                }
            }
        }
    }

    /// 菜单摘要独立于详情窗口的筛选条件, 切换详情不会改变托盘内容
    private func reloadMenuDashboards() {
        menuDashboardTask?.cancel()
        let localOnly = (topologyMode == .localOnly)
        menuDashboardTask = Task { [weak self] in
            guard let self else { return }
            do {
                var results: [UsageMenuScope: UsageDashboard] = [:]
                for scope in UsageMenuScope.allCases {
                    try Task.checkCancellation()
                    results[scope] = try await store.dashboard(
                        filter: UsageFilter(provider: scope.rawValue, days: 210, grouping: .machine, localOnly: localOnly)
                    )
                }
                guard !Task.isCancelled else { return }
                menuDashboards = results
            } catch {
                if !Task.isCancelled {
                    self.error = error.localizedDescription
                }
            }
        }
    }

    func openMenuDetails(section: ControlCenterSection = .usage) {
        activeSection = section
        let targetProvider = visibleMenuScopes.contains(menuScope) ? menuScope.rawValue : ""
        filter = UsageFilter(provider: targetProvider, localOnly: topologyMode == .localOnly)
    }

    func hasSavedRemoteHubToken() async -> Bool {
        let val = await hubClient.loadSecret(account: "remote-hub", isNodeToken: false)
        return val?.isEmpty == false
    }

    private func scheduleRefresh() {
        timerTask?.cancel()
        guard automaticRefresh, !isSleeping else { return }
        timerTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(300)) } catch { return }
                self?.refresh(manual: false)
            }
        }
    }
}
