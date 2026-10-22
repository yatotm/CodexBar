import Combine
import Foundation
import Testing

@MainActor
struct SharedActivityTests {
    @Test func recoveryDoesNotReplayCompletionAndLiveCompletionIsEmittedOnce() throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let preferences = try TestPreferences()
        defer { preferences.remove() }
        let monitor = try makeMonitor(directory, preferences)
        defer { monitor.stop() }
        let now = Date()
        let running = task(at: now)
        var received: [CodexActivityTransition] = []
        let observation = monitor.transitionPublisher.sink { received.append($0) }
        defer { observation.cancel() }
        monitor.receiveSharedTasks([running], available: true, bootstrap: true, now: now)
        #expect(monitor.snapshot.runningTasks.count == 1)
        var completed = task(at: now, state: "completed")
        completed.isHistoricalTerminal = false
        monitor.receiveSharedTasks([completed], available: true, bootstrap: false, now: now)
        monitor.receiveSharedTasks([completed], available: true, bootstrap: false, now: now)
        #expect(received.count == 1)
        #expect(monitor.snapshot.recentCompletions.count == 1)
        #expect(monitor.snapshot.runningTasks.isEmpty)

        monitor.receiveSharedTasks([], available: false, bootstrap: true, now: now)
        monitor.receiveSharedTasks([completed], available: true, bootstrap: true, now: now)
        #expect(received.count == 1)
    }

    @Test func disconnectPausesPowerAndProtectionWithoutInventingTermination() throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let preferences = try TestPreferences()
        defer { preferences.remove() }
        let monitor = try makeMonitor(directory, preferences)
        defer { monitor.stop() }
        let now = Date()
        monitor.receiveSharedTasks([task(at: now)], available: true, bootstrap: true, now: now)
        monitor.receiveSharedTasks([], available: false, bootstrap: true, now: now)
        #expect(!monitor.isMonitoringAvailable)
        #expect(!monitor.isActivitySourceHealthy)
        #expect(monitor.inactivityCheckTask == nil)
        #expect(monitor.snapshot.runningTasks.isEmpty)
        #expect(monitor.snapshot.unconfirmedTasks.count == 1)
        #expect(monitor.snapshot.recentTerminations.isEmpty)
        monitor.receiveSharedTasks([task(at: now)], available: true, bootstrap: true, now: now)
        #expect(monitor.snapshot.unconfirmedTasks.isEmpty)
        #expect(monitor.snapshot.runningTasks.count == 1)
    }

    @Test func heartbeatDoesNotAdvanceProgressAndUsesExistingProtectionIdentity() throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let preferences = try TestPreferences()
        defer { preferences.remove() }
        let monitor = try makeMonitor(directory, preferences)
        defer { monitor.stop() }
        let now = Date()
        var value = task(at: now)
        let oldKey = CodexActivityTaskKey.turn(session: "a", turn: "b")
        value.protectionIdentifier = oldKey.activityProtectionIdentifier
        monitor.receiveSharedTasks([value], available: true, bootstrap: true, now: now)
        let initial = try #require(monitor.tasks.values.first)
        monitor.receiveSharedTasks([value], available: true, bootstrap: false, now: now.addingTimeInterval(30))
        let heartbeat = try #require(monitor.tasks.values.first)
        #expect(heartbeat.key.activityProtectionIdentifier == oldKey.activityProtectionIdentifier)
        #expect(heartbeat.lastProgressAt == initial.lastProgressAt)
        #expect(heartbeat.progressGeneration == initial.progressGeneration)
        #expect(heartbeat.lifecycleCoverageCheckedAt == now.addingTimeInterval(30))
    }

    @Test func disconnectedUnknownTasksExpireWithTheirRetainedState() throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let preferences = try TestPreferences()
        defer { preferences.remove() }
        let monitor = try makeMonitor(directory, preferences)
        defer { monitor.stop() }
        let now = Date()
        monitor.receiveSharedTasks([task(at: now)], available: true, bootstrap: true, now: now)
        monitor.receiveSharedTasks([], available: false, bootstrap: true, now: now)
        #expect(monitor.snapshot.unconfirmedTasks.count == 1)
        monitor.refreshSnapshot(now: now.addingTimeInterval(CodexActivityRetention.window + 1))
        #expect(monitor.tasks.isEmpty)
        #expect(monitor.snapshot.unconfirmedTasks.isEmpty)
        #expect(monitor.snapshot.recentTerminations.isEmpty)
    }

    @Test func asynchronousQuestionAndSubagentRemainRunning() throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let preferences = try TestPreferences()
        defer { preferences.remove() }
        let monitor = try makeMonitor(directory, preferences)
        defer { monitor.stop() }
        let now = Date()
        var value = task(at: now)
        value.pendingInputCount = 1
        value.hasBlockingInputRequest = false
        value.activeSubagentCount = 2
        value.stage = "agent-waiting"
        monitor.receiveSharedTasks([value], available: true, bootstrap: true, now: now)
        #expect(monitor.snapshot.waitingTasks.isEmpty)
        #expect(monitor.snapshot.runningTasks.first?.activeSubagentCount == 2)
        #expect(monitor.snapshot.runningTasks.first?.pendingInputCount == 1)
    }

    @Test func codexDisconnectDoesNotHideHealthyClaudeOnSameHost() {
        var source = UsageSource.local
        source.transport = .ssh
        source.address = "example"
        let now = Date()
        let codex = task(at: now)
        let claude = RemoteActivityTask(
            id: String(repeating: "b", count: 64),
            provider: "claude",
            state: "running",
            project: "project",
            updatedAt: now.timeIntervalSince1970,
            startedAt: now.timeIntervalSince1970 - 20,
            modelName: "claude"
        )
        let merged = ActivityPresentationModel.merge(
            local: .empty, tasks: [source.id: [codex, claude]],
            states: [source.id: "部分连接", source.id + ":codex": "已暂停", source.id + ":claude": "实时连接"],
            enabled: [source.id], sources: [source], scope: .all, now: now
        )
        #expect(merged.runningTasks.count == 1)
        #expect(merged.runningTasks.first?.modelName == "claude")
        #expect(merged.unconfirmedTasks.count == 1)
    }

    @Test func unconfirmedTaskKeepsSuppressionUntilActualProgressResumes() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let preferences = try TestPreferences()
        defer { preferences.remove() }
        let monitor = try makeMonitor(directory, preferences)
        defer { monitor.stop() }
        let now = Date()
        var value = task(at: now.addingTimeInterval(-7200))
        let identifier = try #require(CodexActivityTaskKey.turn(session: "a", turn: "b").activityProtectionIdentifier)
        value.protectionIdentifier = identifier
        monitor.activityProtectionRecords[identifier] = ActivityProtectionRecord(
            taskIdentifier: identifier, lastProgressAt: Date(timeIntervalSince1970: value.updatedAt),
            markedAt: now.addingTimeInterval(-60), expiresAt: now.addingTimeInterval(3600)
        )
        monitor.setActivityProtectionEnabled(true)
        var notices = 0
        monitor.onInactivityProtectionTriggered = { _ in notices += 1
            return true
        }
        monitor.receiveSharedTasks([value], available: true, bootstrap: true, now: now)
        let initial = try #require(monitor.tasks.values.first)
        #expect(initial.state == .suppressed)

        var unknown = task(at: now.addingTimeInterval(-7200), state: "unknown")
        unknown.protectionIdentifier = identifier
        unknown.lifecycleComplete = false
        unknown.lastProgressAt = now.timeIntervalSince1970
        monitor.receiveSharedTasks([unknown], available: true, bootstrap: false, now: now)
        #expect(monitor.tasks.values.first?.state == .suppressed)
        #expect(monitor.tasks.values.first?.lastProgressAt == initial.lastProgressAt)
        #expect(monitor.snapshot.unconfirmedTasks.isEmpty)

        monitor.receiveSharedTasks([value], available: true, bootstrap: false, now: now)
        #expect(monitor.tasks.values.first?.state == .suppressed)
        #expect(monitor.tasks.values.first?.displayID == initial.displayID)
        #expect(monitor.snapshot.runningTasks.isEmpty)
        #expect(monitor.activityProtectionRecords[identifier] != nil)
        #expect(monitor.inactivityCheckTask == nil)
        #expect(notices == 0)

        let progressed = RemoteActivityTask(
            id: value.id, provider: "codex", state: "running", project: value.project,
            updatedAt: now.timeIntervalSince1970, startedAt: value.startedAt, modelName: value.modelName,
            lifecycleComplete: true, lastProgressAt: now.timeIntervalSince1970, protectionIdentifier: identifier
        )
        monitor.receiveSharedTasks([progressed], available: true, bootstrap: false, now: now)
        #expect(monitor.snapshot.runningTasks.count == 1)
        #expect(monitor.snapshot.runningTasks.first?.id == initial.displayID)
        #expect(monitor.activityProtectionRecords[identifier] == nil)
        #expect(notices == 0)
        await monitor.activityProtectionPersistenceTask?.value
    }

    @Test(arguments: ["waiting", "completed"])
    func perTaskRecoveryDoesNotReplayNotifications(_ recoveredState: String) throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let preferences = try TestPreferences()
        defer { preferences.remove() }
        let monitor = try makeMonitor(directory, preferences)
        defer { monitor.stop() }
        let now = Date()
        var transitions: [CodexActivityTransition] = []
        let observation = monitor.transitionPublisher.sink { transitions.append($0) }
        defer { observation.cancel() }
        monitor.receiveSharedTasks([task(at: now)], available: true, bootstrap: true, now: now)
        let identifier = try #require(monitor.tasks.values.first?.displayID)
        monitor.receiveSharedTasks([task(at: now, state: "unknown")], available: true, bootstrap: false, now: now)
        #expect(monitor.tasks.values.first?.state == .unconfirmed)
        #expect(monitor.snapshot.runningTasks.isEmpty)
        #expect(monitor.snapshot.unconfirmedTasks.first?.id == identifier)
        monitor.receiveSharedTasks([task(at: now, state: recoveredState)], available: true, bootstrap: false, now: now)
        #expect(transitions.isEmpty)
        #expect(monitor.snapshot.unconfirmedTasks.isEmpty)
    }

    private func task(at now: Date, state: String = "running") -> RemoteActivityTask {
        RemoteActivityTask(
            id: String(repeating: "a", count: 64),
            provider: "codex",
            state: state,
            project: "project",
            updatedAt: now.timeIntervalSince1970,
            startedAt: now.timeIntervalSince1970 - 20,
            modelName: "gpt-6.1",
            lifecycleComplete: true,
            lastProgressAt: now.timeIntervalSince1970
        )
    }

    private func makeMonitor(_ directory: TestDirectory, _ preferences: TestPreferences) throws -> CodexActivityMonitor {
        let suite = preferences.suite
        let service = try Self.service(suite: suite)
        let monitor = CodexActivityMonitor(
            codexHookSettings: CodexHookSettings(hooksURL: directory.url.appendingPathComponent("hooks.json"), codexStatusService: service),
            activityProtectionSettings: ActivityProtectionSettings(defaults: preferences.defaults),
            activityProtectionStateStore: ActivityProtectionStateStore(directoryURL: directory.url), usesSharedBackend: true
        )
        monitor.isStarted = true
        monitor.isActivityProtectionStateLoaded = true
        return monitor
    }

    private nonisolated static func service(suite: String) throws -> CodexStatusService {
        try CodexStatusService(defaults: #require(UserDefaults(suiteName: suite)))
    }
}
