import Foundation
import Testing

struct CodexActivityTaskDetailsTests {
    private let now = Date(timeIntervalSince1970: 1792713600)

    @Test func legacySourcesKeepExistingDetails() {
        let task = task()
        #expect(CodexActivityTaskDetails.components(for: task, now: now, isWaiting: false)
            == CodexActivityDisplayFormat.runningDetailComponents(for: task, now: now))
        #expect(CodexActivityTaskDetails.components(for: task, now: now, isWaiting: true)
            == CodexActivityDisplayFormat.waitingDetailComponents(for: task, now: now))
    }

    @Test func planAndPendingReplyDoNotReclassifyRunningBackgroundWork() {
        var task = task()
        task.stageTitle = "等待子 Agent"
        task.planCompleted = 1
        task.planTotal = 3
        task.pendingInputCount = 2
        task.hasBlockingInputRequest = false
        task.recentEvent = "最近工具已完成"
        let components = CodexActivityTaskDetails.components(for: task, now: now, isWaiting: false)
        #expect(components.first == task.stageTitle)
        #expect(components.contains { $0.contains("1/3") })
        #expect(components.last == CodexActivityDisplayFormat.runningDurationFragment(since: now.addingTimeInterval(-60), now: now))
        #expect(CodexActivityTaskDetails.help(for: task, now: now, isWaiting: false).hasSuffix("\n最近工具已完成"))
    }

    @Test func incompletePlanAndEmptyStageDoNotInventProgress() {
        var task = task()
        task.stageTitle = " \n "
        task.planTotal = 3
        task.pendingInputCount = 0
        let baseline = CodexActivityDisplayFormat.runningDetailComponents(for: task, now: now)
        #expect(CodexActivityTaskDetails.components(for: task, now: now, isWaiting: false) == baseline)
        task.planCompleted = 4
        #expect(CodexActivityTaskDetails.components(for: task, now: now, isWaiting: false) == baseline)
        #expect(CodexActivityDisplayFormat.modelMetadata(modelName: "model", effort: "high", machineName: "host") == "model • high • host")
    }

    private func task() -> CodexActivityTaskSnapshot {
        CodexActivityTaskSnapshot(
            id: UUID(), isAnonymous: false, latestEvent: .promptSubmitted,
            projectName: "project", modelName: "model", effort: "high", toolName: nil,
            startedAt: now.addingTimeInterval(-60), stateChangedAt: now.addingTimeInterval(-30),
            showsPreciseDuration: true, activeSubagentCount: nil
        )
    }
}
