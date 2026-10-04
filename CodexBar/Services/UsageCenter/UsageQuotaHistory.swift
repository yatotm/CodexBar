import Combine
import Foundation

private actor UsageQuotaHistoryCache {
    private let directory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/CodexBar-yatotm/UsageQuotaHistory", isDirectory: true)
    private let tokenDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/CodexBar-yatotm/UsageTokenHistory", isDirectory: true)

    func read(_ key: String) -> UsageSourceQuotaEvidence? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(key + ".json")), data.count <= 8 * 1024 * 1024,
              let value = try? JSONDecoder().decode(UsageSourceQuotaEvidence.self, from: data), value.isValid else { return nil }
        return value
    }

    func write(_ value: UsageSourceQuotaEvidence, key: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = directory.appendingPathComponent(key + ".json")
        try JSONEncoder().encode(value).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    func readTokens(_ key: String) -> UsageSourceTokenEvidence? {
        guard let data = try? Data(contentsOf: tokenDirectory.appendingPathComponent(key + ".json")), data.count <= 8 * 1024 * 1024,
              let value = try? JSONDecoder().decode(UsageSourceTokenEvidence.self, from: data), value.isValid else { return nil }
        return value
    }

    func writeTokens(_ value: UsageSourceTokenEvidence, key: String) throws {
        try FileManager.default.createDirectory(at: tokenDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = tokenDirectory.appendingPathComponent(key + ".json")
        try JSONEncoder().encode(value).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}

@MainActor
final class UsageQuotaHistoryController {
    private(set) var sources: [UsageSource] = []
    private(set) var accountKey: String?
    private(set) var isRefreshing = false
    private var quotaErrors: [String: String] = [:]
    private var tokenErrors: [String: String] = [:]
    var errors: [String: String] {
        quotaErrors.merging(tokenErrors) { first, _ in first }
    }

    var onUpdate: (() -> Void)?
    private var selected = Set<String>()
    private var localEnabled = false
    private var evidence: [String: UsageSourceQuotaEvidence] = [:]
    private var tokenEvidence: [String: UsageSourceTokenEvidence] = [:]
    private let cache = UsageQuotaHistoryCache()
    private let client = UsageCollectorClient()
    private var task: Task<Void, Never>?
    private var generation = 0
    private var isPaused = false

    var eligibleSources: [UsageSource] {
        sources.filter { $0.isEnabled && $0.includesCodex && $0.transport != .https }
    }

    func isSelected(_ source: UsageSource) -> Bool {
        source.id == "local" ? localEnabled : selected.contains(source.id)
    }

    func setSources(_ sources: [UsageSource]) {
        guard self.sources != sources else { return }
        stop()
        self.sources = sources
        quotaErrors = quotaErrors.filter { id, _ in eligibleSources.contains { $0.id == id } }
        tokenErrors = tokenErrors.filter { id, _ in eligibleSources.contains { $0.id == id } }
        onUpdate?()
        refresh()
    }

    func setAccount(_ key: String, localEnabled: Bool) {
        if accountKey != key {
            stop()
            accountKey = key
            evidence = [:]
            tokenEvidence = [:]
            quotaErrors = [:]
            tokenErrors = [:]
            selected = Set(UserDefaults.standard.stringArray(forKey: "UsageAnalytics.historySources." + key) ?? [])
        }
        if self.localEnabled != localEnabled {
            stop()
        }
        self.localEnabled = localEnabled
        onUpdate?()
    }

    func setSelected(_ source: UsageSource, enabled: Bool) {
        guard let accountKey else { return }
        stop()
        if enabled {
            selected.insert(source.id)
        } else {
            selected.remove(source.id)
            quotaErrors[source.id] = nil
            tokenErrors[source.id] = nil
        }
        UserDefaults.standard.set(selected.sorted(), forKey: "UsageAnalytics.historySources." + accountKey)
        onUpdate?()
        refresh()
    }

    var windows: [UsageObservedWindow] {
        activeEvidence.flatMap(\.windows)
    }

    var plans: [UsagePlanObservation] {
        activeEvidence.flatMap(\.plans)
    }

    var tokenSources: [UsageTokenSource] {
        guard let accountKey else { return [] }
        return eligibleSources.filter(isSelected).compactMap { source in
            guard let value = tokenEvidence[scope(source, account: accountKey)], value.matches(accountKey) else { return nil }
            return UsageTokenSource(name: source.name, evidence: value)
        }
    }

    var selectedSourceCount: Int {
        eligibleSources.filter(isSelected).count
    }

    private var activeEvidence: [UsageSourceQuotaEvidence] {
        guard let accountKey else { return [] }
        return eligibleSources.filter(isSelected).compactMap { source in
            evidence[scope(source, account: accountKey)].flatMap { $0.matches(accountKey) ? $0 : nil }
        }
    }

    private func scope(_ source: UsageSource, account: String) -> String {
        let fields = [account, source.id, source.transport.rawValue, source.address, source.codexHome, source.claudeHome, source.collectorCacheDirectory ?? ""]
        let data = (try? JSONSerialization.data(withJSONObject: fields, options: [.withoutEscapingSlashes])) ?? Data()
        return UsageAnalyticsIdentity.hash("quota-source", String(data: data, encoding: .utf8) ?? "")
    }

    func stop() {
        generation += 1
        task?.cancel()
        task = nil
        isRefreshing = false
    }

    func setPaused(_ paused: Bool) {
        isPaused = paused
        if paused {
            stop()
        }
    }

    private func needsScan(_ value: UsageSourceQuotaEvidence, alreadyScanned: Bool) -> Bool {
        !value.ready || !value.complete || (!alreadyScanned && Date().timeIntervalSince1970 - value.scannedAt > 900)
    }

    func refresh(force: Bool = false) {
        guard !isPaused, task == nil, let account = accountKey else { return }
        let candidates = eligibleSources.filter(isSelected)
        guard !candidates.isEmpty else { return }
        let currentGeneration = generation
        isRefreshing = true
        onUpdate?()
        task = Task { [weak self] in
            guard let self else { return }
            defer {
                if generation == currentGeneration {
                    task = nil
                    isRefreshing = false
                    onUpdate?()
                }
            }
            for source in candidates {
                if Task.isCancelled {
                    return
                }
                let key = scope(source, account: account)
                if evidence[key] == nil, let saved = await cache.read(key), saved.matches(account) {
                    guard generation == currentGeneration else { return }
                    evidence[key] = saved
                    onUpdate?()
                }
                do {
                    var scan = source.transport == .local || source.collectorCacheDirectory?.isEmpty != false
                    for _ in 0 ..< 4 {
                        let value = try await client.fetchQuotaHistory(source: source, account: account, scan: scan)
                        try Task.checkCancellation()
                        guard generation == currentGeneration, isSelected(source),
                              eligibleSources.contains(where: { scope($0, account: account) == key }) else { break }
                        if value.ready {
                            evidence[key] = value
                            try await cache.write(value, key: key)
                            try Task.checkCancellation()
                            quotaErrors[source.id] = value.complete ? nil : source.name + ": 历史周限仍在回填"
                            onUpdate?()
                        }
                        if !needsScan(value, alreadyScanned: scan) {
                            break
                        }
                        scan = true
                    }
                } catch is CancellationError {
                    return
                } catch {
                    guard generation == currentGeneration else { return }
                    quotaErrors[source.id] = source.name + ": " + ((error as? UsageCenterError)?.message ?? "额度历史读取失败, 保留缓存")
                    onUpdate?()
                }
                await refreshTokens(source, account: account, key: key, generation: currentGeneration, force: force)
            }
        }
    }

    private func refreshTokens(_ source: UsageSource, account: String, key: String, generation expected: Int, force: Bool) async {
        guard !Task.isCancelled, generation == expected else { return }
        if tokenEvidence[key] == nil, let saved = await cache.readTokens(key), saved.matches(account) {
            guard generation == expected else { return }
            tokenEvidence[key] = saved
            onUpdate?()
        }
        if !force, let value = tokenEvidence[key], value.ready, value.complete,
           Date().timeIntervalSince1970 - value.scannedAt < 900 {
            return
        }
        do {
            for _ in 0 ..< 4 {
                let value = try await client.fetchTokenHistory(source: source, account: account, scan: true)
                try Task.checkCancellation()
                guard generation == expected, isSelected(source),
                      eligibleSources.contains(where: { scope($0, account: account) == key }) else { return }
                if value.ready {
                    tokenEvidence[key] = value
                    try await cache.writeTokens(value, key: key)
                    try Task.checkCancellation()
                    tokenErrors[source.id] = value.complete ? nil : source.name + ": Token 历史仍在回填"
                    onUpdate?()
                }
                if value.complete {
                    break
                }
            }
        } catch is CancellationError {
            return
        } catch {
            guard generation == expected else { return }
            tokenErrors[source.id] = source.name + ": " + ((error as? UsageCenterError)?.message ?? "Token 历史读取失败, 保留缓存")
            onUpdate?()
        }
    }
}
