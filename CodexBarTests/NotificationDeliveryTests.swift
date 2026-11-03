import Foundation
import Testing
import UserNotifications

@MainActor
struct NotificationDeliveryTests {
    @Test(arguments: [false, true])
    func resolvedWaitingIsWithdrawnWhileSubagentsAndAsyncQuestionsContinue(blockingQuestion: Bool) async throws {
        let fixture = try NotificationFixture()
        defer { fixture.stop() }
        try await fixture.start()
        fixture.publishWaiting(blockingQuestion: blockingQuestion)
        try await waitUntil { fixture.recorder.delivered.count == 1 }
        fixture.publishRunning()
        #expect(fixture.recorder.delivered.isEmpty)
        #expect(fixture.monitor.snapshot.runningTasks.first?.activeSubagentCount == 3)
        #expect(fixture.monitor.snapshot.waitingTasks.isEmpty)
    }

    @Test func waitingResolvedBeforeSubmissionDoesNotSend() async throws {
        let fixture = try NotificationFixture()
        defer { fixture.stop() }
        try await fixture.start()
        fixture.publishWaiting(blockingQuestion: true)
        fixture.publishRunning()
        await Task.yield()
        await Task.yield()
        #expect(fixture.recorder.requests.isEmpty)
    }

    @Test func lateSubmissionCannotWithdrawANewerWaitForTheSameTask() async throws {
        let fixture = try NotificationFixture()
        defer { fixture.stop() }
        try await fixture.start()
        fixture.recorder.suspendsNextSubmission = true
        fixture.publishWaiting(blockingQuestion: true)
        try await waitUntil { fixture.recorder.pending != nil }
        let firstID = try #require(fixture.recorder.requests.first?.identifier)
        fixture.publishRunning()
        fixture.publishWaiting(blockingQuestion: false)
        try await waitUntil { fixture.recorder.delivered.count == 1 }
        let currentID = try #require(fixture.recorder.delivered.first)
        #expect(firstID != currentID)
        fixture.recorder.releasePending()
        try await waitUntil { fixture.recorder.completedSubmissions == 2 }
        #expect(fixture.recorder.delivered == [currentID])
        fixture.publishRunning()
        #expect(fixture.recorder.delivered.isEmpty)
    }

    @Test(arguments: ["codex", "claude"])
    func remoteWaitsAreWithdrawnIndependentlyByMachineAndConnection(provider: String) async throws {
        let fixture = try NotificationFixture()
        defer { fixture.stop() }
        try await fixture.start()
        var waiting = fixture.task(state: "waiting", provider: provider)
        if provider == "claude" {
            waiting.stage = nil
            waiting.toolName = "AskUserQuestion"
        }
        fixture.service.reconcileRemoteActivity(
            tasks: ["first": [waiting], "second": [waiting]],
            states: ["first": "实时连接", "second": "实时连接"]
        )
        let first = try #require(fixture.service.notifyRemoteActivity(waiting, sourceID: "first", sourceName: "First"))
        let second = try #require(fixture.service.notifyRemoteActivity(waiting, sourceID: "second", sourceName: "Second"))
        #expect(await first.value)
        #expect(await second.value)
        #expect(fixture.recorder.delivered.count == 2)
        #expect(fixture.recorder.requests.allSatisfy {
            $0.content.title.contains(String(localized: "activity.stage.waiting-input", defaultValue: "等待回应"))
        })
        fixture.service.reconcileRemoteActivity(
            tasks: ["first": [fixture.task(state: "running", provider: provider)], "second": [waiting]],
            states: ["first": "实时连接", "second": "实时连接"]
        )
        #expect(fixture.recorder.delivered.count == 1)
        fixture.service.reconcileRemoteActivity(tasks: ["second": [waiting]], states: ["second": "已暂停"])
        #expect(fixture.recorder.delivered.isEmpty)
    }

    @Test func explicitNonblockingInputDoesNotCreateWaitingNotification() async throws {
        let fixture = try NotificationFixture()
        defer { fixture.stop() }
        try await fixture.start()
        var task = fixture.task(state: "waiting", provider: "claude")
        task.hasBlockingInputRequest = false
        task.activeSubagentCount = 3
        #expect(fixture.service.notifyRemoteActivity(task, sourceID: "remote", sourceName: "Remote") == nil)
        #expect(fixture.recorder.requests.isEmpty)
    }

    @Test func reappearingQuotaWindowStartsANewThresholdObservation() async throws {
        let fixture = try NotificationFixture(lowQuotaEnabled: false)
        defer { fixture.stop() }
        try await fixture.start()
        let snapshot = try fixture.quota(used: 95)
        fixture.service.handleSnapshot(snapshot)
        try fixture.service.handleSnapshot(fixture.quota(used: nil))
        fixture.settings.setLowQuotaEnabled(true)
        fixture.service.handleSnapshot(snapshot)
        try await waitUntil { fixture.preferences.defaults.stringArray(forKey: "Notification.sentKeys")?.count == 1 }
        #expect(fixture.recorder.delivered.count == 1)
        fixture.service.handleSnapshot(snapshot)
        await Task.yield()
        #expect(fixture.recorder.requests.count == 1)
    }

    @Test func staleQuotaDoesNotCreateThresholdNotifications() async throws {
        let fixture = try NotificationFixture()
        defer { fixture.stop() }
        try await fixture.start()
        try fixture.service.handleSnapshot(fixture.quota(used: 99, stale: true))
        await Task.yield()
        #expect(fixture.recorder.requests.isEmpty)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(condition())
    }
}

@MainActor
private final class NotificationFixture {
    let directory: TestDirectory
    let preferences: TestPreferences
    let settings: NotificationSettings
    let monitor: CodexActivityMonitor
    let service: CodexNotificationService
    let recorder = NotificationRecorder()
    private let startedAt = Date().addingTimeInterval(-30)

    init(lowQuotaEnabled: Bool = true) throws {
        directory = try TestDirectory()
        preferences = try TestPreferences()
        preferences.defaults.set(true, forKey: "Notification.enabled")
        preferences.defaults.set(lowQuotaEnabled, forKey: "Notification.lowQuotaEnabled")
        preferences.defaults.set(false, forKey: "Notification.quotaResetEnabled")
        settings = NotificationSettings(defaults: preferences.defaults, readAuthorizationStatus: { .authorized })
        let backend = try Self.backend(suite: preferences.suite, socketURL: directory.url.appendingPathComponent("unused.sock"))
        monitor = CodexActivityMonitor(
            codexHookSettings: CodexHookSettings(hooksURL: directory.url.appendingPathComponent("hooks.json"), codexStatusService: backend),
            activityProtectionSettings: ActivityProtectionSettings(defaults: preferences.defaults),
            activityProtectionStateStore: ActivityProtectionStateStore(directoryURL: directory.url), usesSharedBackend: true
        )
        monitor.isStarted = true
        monitor.isActivityProtectionStateLoaded = true
        let model = CodexStatusViewModel(service: backend, defaults: preferences.defaults)
        service = CodexNotificationService(
            settings: settings, statusViewModel: model, activityMonitor: monitor,
            defaults: preferences.defaults, delivery: recorder.client, openMenuSurface: {}
        )
    }

    func start() async throws {
        service.start()
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !settings.canDeliver, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(settings.canDeliver)
        monitor.receiveSharedTasks([task(state: "running")], available: true, bootstrap: true)
    }

    func task(state: String, provider: String = "codex") -> RemoteActivityTask {
        let now = Date().timeIntervalSince1970
        return RemoteActivityTask(
            id: String(repeating: "a", count: 64), provider: provider, state: state, project: "project",
            updatedAt: now, startedAt: startedAt.timeIntervalSince1970, modelName: "test-model",
            stateChangedAt: now, activeSubagentCount: 3, stage: state == "waiting" ? "waiting-input" : "agent-waiting",
            pendingInputCount: 1, hasBlockingInputRequest: state == "waiting", lifecycleComplete: true, lastProgressAt: now
        )
    }

    func publishWaiting(blockingQuestion: Bool) {
        var waiting = task(state: "waiting")
        waiting.stage = blockingQuestion ? "waiting-input" : "waiting-approval"
        monitor.receiveSharedTasks([waiting], available: true, bootstrap: false)
    }

    func publishRunning() {
        monitor.receiveSharedTasks([task(state: "running")], available: true, bootstrap: false)
    }

    func quota(used: Int?, stale: Bool = false) throws -> CodexQuotaSnapshot {
        let response = try TestFixtures.decode(AccountRateLimitsResponse.self, used.map {
            "{\"rateLimits\":{\"primary\":{\"usedPercent\":\($0),\"resetsAt\":2000000000}}}"
        } ?? "{\"rateLimits\":{}}")
        return try CodexQuotaSnapshot(
            accountResponse: AccountReadResponse(account: CodexAccount(type: "chatgpt", email: "test@example.com", planType: "pro")),
            rateLimitsResponse: response, isRateLimitsStale: stale
        )
    }

    func stop() {
        recorder.releasePending()
        monitor.stop()
        preferences.remove()
        try? directory.remove()
    }

    private nonisolated static func backend(suite: String, socketURL: URL) throws -> CodexStatusService {
        try CodexStatusService(defaults: #require(UserDefaults(suiteName: suite)), socketURL: socketURL)
    }
}

@MainActor
private final class NotificationRecorder {
    var requests: [UNNotificationRequest] = []
    var delivered = Set<String>()
    var completedSubmissions = 0
    var suspendsNextSubmission = false
    var pending: CheckedContinuation<Void, Never>?

    var client: CodexNotificationService.Delivery {
        CodexNotificationService.Delivery(setDelegate: { _ in }, add: { [self] request in
            requests.append(request)
            if suspendsNextSubmission {
                suspendsNextSubmission = false
                await withCheckedContinuation { pending = $0 }
            }
            delivered.insert(request.identifier)
            completedSubmissions += 1
        }, remove: { [self] ids in delivered.subtract(ids) })
    }

    func releasePending() {
        let continuation = pending
        pending = nil
        continuation?.resume()
    }
}
