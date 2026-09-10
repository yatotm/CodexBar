import AppKit
import Combine
import Foundation

@MainActor
final class UsageCenterViewModel: ObservableObject {
    @Published private(set) var sources: [UsageSource] = [] {
        didSet {
            analytics.history.setSources(sources)
            remoteActivity.setSources(sources)
        }
    }

    @Published private(set) var statuses: [String: UsageSourceStatus] = [:]
    @Published private(set) var dashboard = UsageDashboard()
    @Published private(set) var dashboardFilter: UsageFilter?
    @Published private(set) var menuDashboards: [UsageMenuScope: UsageDashboard] = [:]
    @Published var menuScope = UsageMenuScope.all
    @Published private(set) var isRefreshing = false
    @Published private(set) var refreshingSource = ""
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
    private let store = UsageCenterStore()
    private let client = UsageCollectorClient()
    private var refreshTask: Task<Void, Never>?
    private var timerTask: Task<Void, Never>?
    private var dashboardTask: Task<Void, Never>?
    private var menuDashboardTask: Task<Void, Never>?
    private var failures: [String: Int] = [:]
    private var nextAttempts: [String: Date] = [:]
    private var isSleeping = false

    func start() {
        Task { [weak self] in
            guard let self else { return }
            do {
                sources = try await store.sources()
                if sources.isEmpty {
                    try await store.save(.local)
                    sources = [.local]
                }
                for source in sources {
                    statuses[source.id] = try await store.status(for: source)
                }
                reloadDashboard()
                reloadMenuDashboards()
                if automaticRefresh {
                    refresh(manual: false)
                }
                scheduleRefresh()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    func stop() {
        remoteActivity.stop()
        refreshTask?.cancel()
        timerTask?.cancel()
        dashboardTask?.cancel()
        menuDashboardTask?.cancel()
        analytics.stop()
    }

    func pauseForSleep() {
        guard !isSleeping else { return }
        isSleeping = true
        cancelRefresh()
        timerTask?.cancel()
        timerTask = nil
        analytics.pauseForSleep()
    }

    func resumeAfterWake() {
        guard isSleeping else { return }
        isSleeping = false
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
                reloadDashboard()
                reloadMenuDashboards()
            }
            do {
                sources = try await store.sources()
            } catch {
                self.error = error.localizedDescription
                return
            }
            for source in sources where source.isEnabled {
                if Task.isCancelled {
                    break
                }
                if !manual, let next = nextAttempts[source.id], next > Date() {
                    continue
                }
                refreshingSource = source.name
                do {
                    try await refresh(source)
                    failures[source.id] = 0
                    nextAttempts[source.id] = nil
                } catch is CancellationError {
                    break
                } catch {
                    var status = statuses[source.id] ?? UsageSourceStatus()
                    status.error = error.localizedDescription
                    statuses[source.id] = status
                    let failureCount = min(6, (failures[source.id] ?? 0) + 1)
                    failures[source.id] = failureCount
                    nextAttempts[source.id] = Date().addingTimeInterval(min(3600, 300 * pow(2, Double(failureCount - 1))))
                }
            }
        }
    }

    private func refresh(_ source: UsageSource) async throws {
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

    func cancelRefresh() {
        refreshTask?.cancel()
    }

    func configureClaude(source: UsageSource, install: Bool) async -> Bool {
        guard !isRefreshing else { return false }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            try await client.configureClaude(source: source, install: install)
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
            try await store.remove(source)
            remoteActivity.setEnabled(false, sourceID: source.id)
            await client.deleteToken(for: source.id)
            sources = try await store.sources()
            statuses[source.id] = nil
            if filter.sourceID == source.id {
                filter.sourceID = ""
            }
            reloadDashboard()
            reloadMenuDashboards()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func reloadDashboard() {
        dashboardTask?.cancel()
        let requestedFilter = filter
        dashboardTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await store.dashboard(filter: requestedFilter)
                guard !Task.isCancelled, requestedFilter == filter else { return }
                dashboard = result
                dashboardFilter = requestedFilter
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
        menuDashboardTask = Task { [weak self] in
            guard let self else { return }
            do {
                var results: [UsageMenuScope: UsageDashboard] = [:]
                for scope in UsageMenuScope.allCases {
                    try Task.checkCancellation()
                    results[scope] = try await store.dashboard(filter: UsageFilter(provider: scope.rawValue, days: 210, grouping: .machine))
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

    var menuSources: [UsageSource] {
        sources.filter(menuScope.includes)
    }

    var menuDashboard: UsageDashboard? {
        menuDashboards[menuScope]
    }

    var latestClaudeQuota: UsageQuotaObservation? {
        var latest: UsageQuotaObservation?
        for source in sources where UsageMenuScope.claude.includes(source) {
            for quota in statuses[source.id]?.quotas ?? [] where quota.provider == "claude" {
                if quota.observedAt > (latest?.observedAt ?? 0) {
                    latest = quota
                }
            }
        }
        return latest
    }

    func openMenuDetails() {
        filter = UsageFilter(provider: menuScope.rawValue)
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
