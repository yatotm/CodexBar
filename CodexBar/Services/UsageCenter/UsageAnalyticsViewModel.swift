import Combine
import Foundation

@MainActor
final class UsageAnalyticsViewModel: ObservableObject {
    @Published private(set) var snapshot: UsageAnalyticsSnapshot?
    @Published private(set) var periods: [UsageAnalyticsPeriod] = []
    @Published private(set) var prices: UsagePriceBook?
    @Published private(set) var isRefreshing = false
    @Published private(set) var error: String?
    let history = UsageQuotaHistoryController()
    var isImportingHistory: Bool {
        history.isRefreshing
    }

    init() {
        history.onUpdate = { [weak self] in
            self?.objectWillChange.send()
            self?.recalculate()
        }
    }

    @Published private(set) var planHistory = UsagePlanHistory()
    @Published var quotaReference = UsageQuotaReference.disabled {
        didSet {
            guard !restoringConsent, let activeAccountKey else { return }
            UserDefaults.standard.set(quotaReference.rawValue, forKey: "UsageAnalytics.quotaReference." + activeAccountKey)
        }
    }

    @Published var includesLocalHistory = false {
        didSet {
            guard !restoringConsent, let activeAccountKey else { return }
            UserDefaults.standard.set(includesLocalHistory, forKey: "UsageAnalytics.import." + activeAccountKey)
            history.setAccount(activeAccountKey, localEnabled: includesLocalHistory)
            history.refresh()
        }
    }

    private var activeAccountKey: String?
    private var restoringConsent = false
    private let client = UsageAnalyticsClient()
    private var timer: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var calculation: Task<Void, Never>?
    private var pendingQuota: CodexQuotaSnapshot?
    private var isSleeping = false

    func start() {
        guard !isSleeping, timer == nil else { return }
        refresh()
        timer = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(900)) } catch { return }
                self?.refresh()
            }
        }
    }

    func stop() {
        timer?.cancel()
        timer = nil
        refreshTask?.cancel()
        history.stop()
        calculation?.cancel()
    }

    func pauseForSleep() {
        isSleeping = true
        stop()
        history.setPaused(true)
    }

    func resumeAfterWake() {
        guard isSleeping else { return }
        isSleeping = false
        history.setPaused(false)
        start()
    }

    func refresh(force: Bool = false) {
        guard !isSleeping, refreshTask == nil else { return }
        isRefreshing = true
        error = nil
        refreshTask = Task { [weak self] in
            guard let self else { return }
            defer { isRefreshing = false
                refreshTask = nil
            }
            do {
                let key = try await client.accountKey()
                if activeAccountKey != key {
                    activeAccountKey = key
                    calculation?.cancel()
                    snapshot = nil
                    periods = []
                    restoringConsent = true
                    includesLocalHistory = UserDefaults.standard.bool(forKey: "UsageAnalytics.import." + key)
                    quotaReference = UsageQuotaReference(rawValue: UserDefaults.standard.string(forKey: "UsageAnalytics.quotaReference." + key) ?? "") ?? .disabled
                    planHistory = UserDefaults.standard.data(forKey: "UsageAnalytics.planHistory." + key)
                        .flatMap { try? JSONDecoder().decode(UsagePlanHistory.self, from: $0) } ?? UsagePlanHistory()
                    restoringConsent = false
                    history.setAccount(key, localEnabled: includesLocalHistory)
                    snapshot = try await client.restore()
                    periods = []
                }
                prices = try await client.prices()
                if !force, let snapshot, Date().timeIntervalSince(snapshot.fetchedAt) < 900 {
                    recalculate()
                } else {
                    var latest = try await client.fetch()
                    try Task.checkCancellation()
                    if snapshot?.accountKey == latest.accountKey {
                        latest.windows = UsageAnalyticsValuation.merge((snapshot?.windows ?? []) + latest.windows)
                        latest.importedHistory = snapshot?.importedHistory ?? false
                    }
                    snapshot = latest
                    try await client.save(latest)
                    recalculate()
                }
                if let pendingQuota {
                    observe(pendingQuota)
                }
                history.refresh()
            } catch {
                if !Task.isCancelled {
                    let currentKey = try? await client.accountKey()
                    if currentKey != snapshot?.accountKey {
                        snapshot = nil
                        periods = []
                    }
                    self.error = (error as? UsageCenterError)?.message ?? "官方分析暂不可用或响应格式已变化, 保留上次有效数据"
                }
            }
        }
    }

    func observe(_ quota: CodexQuotaSnapshot) {
        pendingQuota = quota
        guard !quota.isRateLimitsStale, quota.account.type == "chatgpt", let email = quota.account.email,
              var current = snapshot,
              current.emailKey == UsageAnalyticsIdentity.hash("codex-email", email.lowercased()),
              let window = quota.codexLimit?.windows.first(where: { $0.windowDurationMins == 10080 }),
              let reset = window.resetsAt?.timeIntervalSince1970, let used = window.usedPercent else { return }
        let at = quota.generatedAt.timeIntervalSince1970
        if let plan = quota.planType ?? quota.account.planType, let activeAccountKey {
            var updated = planHistory
            updated.observe(plan: plan, at: at, resetsAt: reset)
            if updated.observations != planHistory.observations, let data = try? JSONEncoder().encode(updated) {
                planHistory = updated
                UserDefaults.standard.set(data, forKey: "UsageAnalytics.planHistory." + activeAccountKey)
            }
        }
        if let previous = current.windows.last(where: { abs($0.resetsAt - reset) <= 2 }),
           previous.lastUsed == Double(used), Int(previous.lastAt / 86400) == Int(at / 86400) {
            return
        }
        let sample = UsageObservedWindow(
            resetsAt: reset,
            firstAt: at,
            firstUsed: Double(used),
            lastAt: at,
            lastUsed: Double(used),
            maxUsed: Double(used),
            decreased: false,
            observations: [UsageQuotaPoint(at: at, used: Double(used))]
        )
        current.windows = UsageAnalyticsValuation.merge(current.windows + [sample]).filter { $0.resetsAt > at - 210 * 86400 }
        snapshot = current
        Task { try? await client.save(current) }
        recalculate()
    }

    func reference(for period: UsageAnalyticsPeriod) -> UsageQuotaReference {
        planEntries(for: period).last?.reference ?? quotaReference
    }

    func planTitle(for period: UsageAnalyticsPeriod) -> String {
        let entries = planEntries(for: period)
        let names = entries.reduce(into: [String]()) { result, entry in
            if result.last != entry.title {
                result.append(entry.title)
            }
        }
        return names.joined(separator: " → ")
    }

    func projection(for period: UsageAnalyticsPeriod) -> Double? {
        let plans = Set(planEntries(for: period).map(\.plan))
        return plans.count > 1 ? nil : period.projected
    }

    func planEntries(for period: UsageAnalyticsPeriod) -> [UsagePlanObservation] {
        let sourcePlans = history.accountKey == snapshot?.accountKey ? history.plans : []
        let entries = (planHistory.observations + sourcePlans).filter { abs($0.resetsAt - period.id) <= 2 }.sorted { $0.at < $1.at }
        return entries.reduce(into: []) { result, item in
            if result.last?.plan != item.plan {
                result.append(item)
            }
        }
    }

    private func recalculate() {
        calculation?.cancel()
        guard let snapshot, let prices else { return }
        let sourceWindows = history.accountKey == snapshot.accountKey ? history.windows : []
        calculation = Task { [weak self] in
            let work = Task.detached(priority: .utility) { UsageAnalyticsValuation.periods(snapshot: snapshot, prices: prices, sourceWindows: sourceWindows) }
            let value = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
            guard !Task.isCancelled else { return }
            self?.periods = value
        }
    }
}
