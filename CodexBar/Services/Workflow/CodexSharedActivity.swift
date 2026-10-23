import Combine
import Foundation

extension CodexActivityMonitor {
    /// 心跳只刷新来源健康与覆盖时间, 不作为任务进展
    func receiveSharedTasks(_ values: [RemoteActivityTask], available: Bool, bootstrap: Bool, now: Date = .now) {
        guard usesSharedBackend, isStarted else { return }
        // 与协议同用 Unix 秒, 避免 Date 往返转换把零间隔舍入为负数
        let receivedAt = now.timeIntervalSince1970
        let recovering = bootstrap || !isMonitoringAvailable
        let healthy = updateSharedSourceHealth(available)
        if !healthy {
            sharedUnconfirmedTasks = tasks.values.filter { $0.state != .suppressed }.map(\.snapshot)
            _ = beginActivityProtectionRecovery()
            refreshSnapshot(now: now)
            return
        }

        if recovering {
            _ = beginActivityProtectionRecovery()
        }
        var next: [CodexActivityTaskKey: CodexActivityTask] = [:]
        var transitions: [CodexActivityTransition] = []
        var restoresUnconfirmedTask = false
        sharedUnconfirmedTasks = []
        for value in values where value.provider == "codex" {
            let key = CodexActivityTaskKey.shared(id: value.id, protection: value.protectionIdentifier)
            let previous = tasks[key]
            let task = CodexActivityTask(shared: value, previous: previous, now: now)
            let wasUnconfirmed = previous?.state == .unconfirmed
                || (previous?.state == .suppressed && previous?.lifecycleCoverageCheckedAt == nil)
            let taskRecovering = recovering || wasUnconfirmed
            if value.state == "unknown" {
                next[key] = task
                if task.state != .suppressed {
                    sharedUnconfirmedTasks.append(task.snapshot)
                }
                cancelActivityProtectionAttempt(for: key)
            } else if value.isActive {
                restoresUnconfirmedTask = restoresUnconfirmedTask || wasUnconfirmed
                if let previous, task.lastProgressAt > previous.lastProgressAt || task.state == .waitingApproval {
                    clearActivityProtection(for: key, taskID: task.displayID, reason: .progress)
                }
                next[key] = task
                if !taskRecovering, task.state == .waitingApproval, previous?.state != .waitingApproval,
                   (0 ... 10).contains(receivedAt - (value.stateChangedAt ?? value.updatedAt)) {
                    transitions.append(.waitingApproval(task.snapshot))
                }
            } else {
                let publishes = !taskRecovering && previous != nil && value.isHistoricalTerminal != true
                    && (0 ... 10).contains(receivedAt - value.updatedAt)
                storeSharedTerminal(value, task: task, publishes: publishes, now: now, into: &transitions)
            }
        }
        for (key, task) in tasks where next[key] == nil {
            cancelActivityProtectionAttempt(for: key)
            invalidateActivityProtectionNotification(for: task.displayID)
        }
        tasks = next
        isActivityProtectionRecoveryInProgress = false
        if recovering || restoresUnconfirmedTask {
            sessionTransitionNotBefore = now
            applyPersistedActivityProtection(now: now)
            reconcileActivityProtection(now: now, sendsNotification: false)
        } else {
            refreshSnapshot(now: now)
        }
        for transition in transitions {
            transitionSubject.send(transition)
        }
    }

    private func storeSharedTerminal(
        _ value: RemoteActivityTask, task: CodexActivityTask, publishes: Bool, now: Date,
        into transitions: inout [CodexActivityTransition]
    ) {
        let endedAt = Date(timeIntervalSince1970: value.updatedAt)
        clearActivityProtection(for: task.key, taskID: task.displayID, reason: .terminal)
        guard endedAt > now.addingTimeInterval(-CodexActivityRetention.recentHistory),
              endedAt > (task.startedAt ?? endedAt) else { return }
        let exists = terminalTaskKeyByID[task.displayID] != nil
        terminalTaskKeyByID[task.displayID] = task.key
        let duration = value.lifecycleComplete == true ? task.preciseDuration(until: endedAt) : nil
        if value.state == "completed" {
            let completion = CodexActivityCompletion(
                id: task.displayID, isAnonymous: false, projectName: task.projectName,
                modelName: task.modelName, effort: task.effort, completedAt: endedAt,
                duration: duration, tokenUsage: task.tokenUsage
            )
            completions.removeAll { $0.id == task.displayID }
            completions.append(completion)
            if publishes, !exists {
                transitions.append(.completed(completion))
                pendingTerminalPresentationEvents.append(.completed(completion))
            }
        } else if value.state == "ended" {
            let termination = CodexActivityTermination(
                id: task.displayID, isAnonymous: false, projectName: task.projectName,
                modelName: task.modelName, effort: task.effort, terminatedAt: endedAt,
                duration: duration, tokenUsage: task.tokenUsage
            )
            terminations.removeAll { $0.id == task.displayID }
            terminations.append(termination)
            if publishes, !exists {
                pendingTerminalPresentationEvents.append(.terminated(termination))
            }
        }
    }
}
