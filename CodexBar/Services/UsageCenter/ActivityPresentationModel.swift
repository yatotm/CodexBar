import Combine
import CryptoKit
import Foundation

/// 只合并展示, 本机通知与防睡眠仍由原始监控快照驱动
@MainActor
final class ActivityPresentationModel: ObservableObject {
    @Published private(set) var snapshot = CodexActivitySnapshot.empty
    @Published private(set) var statusItemSnapshot = CodexActivitySnapshot.empty
    @Published private(set) var hasActivitySource = false
    private let presentationSubject = PassthroughSubject<CodexActivityPresentationUpdate, Never>()
    var presentationPublisher: AnyPublisher<CodexActivityPresentationUpdate, Never> {
        presentationSubject.eraseToAnyPublisher()
    }

    private var terminalObservations = Set<AnyCancellable>()
    private var observation: AnyCancellable?
    private var expirationTask: Task<Void, Never>?

    init(local: CodexActivityMonitor, usage: UsageCenterViewModel) {
        let remote = usage.remoteActivity
        observation = Publishers.CombineLatest4(local.$snapshot, remote.$tasks, remote.$states, remote.$enabledSourceIDs)
            .combineLatest(usage.$sources, usage.$menuScope)
            .sink { [weak self] values, sources, scope in
                self?.update(local: values.0, tasks: values.1, states: values.2, enabled: values.3, sources: sources, scope: scope)
            }
        local.presentationPublisher.sink { [weak self] update in
            guard let self, !update.terminalEvents.isEmpty else { return }
            let events = update.terminalEvents.map { event -> CodexActivityTerminalEvent in
                switch event {
                case var .completed(value): value.machineName = "本机"
                    return .completed(value)
                case var .terminated(value): value.machineName = "本机"
                    return .terminated(value)
                }
            }
            presentationSubject.send(.init(snapshot: statusItemSnapshot, terminalEvents: events))
        }.store(in: &terminalObservations)
        remote.terminalPublisher.sink { [weak self] sourceID, task in
            guard let self else { return }
            let id = Self.taskID(source: sourceID, task: task.id, startedAt: task.startedAt)
            let event: CodexActivityTerminalEvent? = if let value = statusItemSnapshot.recentCompletions.first(where: { $0.id == id }), task.state == "completed" {
                .completed(value)
            } else if let value = statusItemSnapshot.recentTerminations.first(where: { $0.id == id }), task.state == "ended" {
                .terminated(value)
            } else {
                nil
            }
            if let event {
                presentationSubject.send(.init(snapshot: statusItemSnapshot, terminalEvents: [event]))
            }
        }.store(in: &terminalObservations)
    }

    deinit {
        expirationTask?.cancel()
    }

    private func update(
        local: CodexActivitySnapshot,
        tasks: [String: [RemoteActivityTask]],
        states: [String: String],
        enabled: Set<String>,
        sources: [UsageSource],
        scope: UsageMenuScope
    ) {
        let now = Date()
        let hasSource = sources.contains { source in
            source.isEnabled && source.validationError == nil && source.transport != .https
                && ((source.transport == .local && source.includesCodex) || enabled.contains(source.id))
        }
        if hasActivitySource != hasSource {
            hasActivitySource = hasSource
        }
        let result = Self.merge(local: local, tasks: tasks, states: states, enabled: enabled, sources: sources, scope: scope, now: now)
        if snapshot != result {
            snapshot = result
        }
        // 菜单栏始终汇总全部工具, 不随面板标签隐藏仍在运行的任务
        let statusResult = scope == .all ? result : Self.merge(local: local, tasks: tasks, states: states, enabled: enabled, sources: sources, scope: .all, now: now)
        if statusItemSnapshot != statusResult {
            statusItemSnapshot = statusResult
            presentationSubject.send(.init(snapshot: statusResult, terminalEvents: []))
        }
        expirationTask?.cancel()
        expirationTask = nil
        let deadlines = tasks.values.flatMap(\.self).map { task in
            Date(timeIntervalSince1970: task.updatedAt + (task.state == "completed" || task.state == "ended"
                    ? CodexActivityRetention.recentHistory : CodexActivityRetention.window))
        }
        guard let deadline = deadlines.filter({ $0 > now }).min() else { return }
        // 心跳不发布相同快照, 到期单次唤醒以清理历史, 不依赖后续任务事件
        expirationTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(deadline.timeIntervalSinceNow))
                try Task.checkCancellation()
            } catch { return }
            self?.update(local: local, tasks: tasks, states: states, enabled: enabled, sources: sources, scope: scope)
        }
    }

    static func merge(
        local: CodexActivitySnapshot,
        tasks: [String: [RemoteActivityTask]],
        states: [String: String],
        enabled: Set<String>,
        sources: [UsageSource],
        scope: UsageMenuScope,
        now: Date = .now
    ) -> CodexActivitySnapshot {
        var waiting = [CodexActivityTaskSnapshot](), running = [CodexActivityTaskSnapshot](), unknown = [CodexActivityTaskSnapshot]()
        var completions = [CodexActivityCompletion](), terminations = [CodexActivityTermination]()
        if scope != .claude {
            waiting = local.waitingTasks.map { var task = $0
                task.machineName = "本机"
                return task
            }
            running = local.runningTasks.map { var task = $0
                task.machineName = "本机"
                return task
            }
            unknown = local.unconfirmedTasks.map { var task = $0
                task.machineName = "本机"
                return task
            }
            completions = local.recentCompletions.map { var task = $0
                task.machineName = "本机"
                return task
            }
            terminations = local.recentTerminations.map { var task = $0
                task.machineName = "本机"
                return task
            }
        }
        for source in sources where source.isEnabled && enabled.contains(source.id) {
            for task in tasks[source.id] ?? [] where scope == .all || scope.rawValue == task.provider {
                guard task.provider == "codex" ? source.includesCodex : source.includesClaude else { continue }
                guard task.provider != "codex" || source.transport != .local else { continue }
                guard task.updatedAt > now.timeIntervalSince1970 - CodexActivityRetention.window else { continue }
                if task.state == "completed" || task.state == "ended" {
                    guard task.updatedAt > now.timeIntervalSince1970 - CodexActivityRetention.recentHistory else { continue }
                    // 旧采集器的孤立 SessionEnd 没有任务起点, 仅在展示层过滤
                    guard task.state != "ended" || task.updatedAt > task.startedAt else { continue }
                }
                let id = taskID(source: source.id, task: task.id, startedAt: task.startedAt)
                let model = task.modelName ?? "未知模型"
                let machine = source.transport == .local ? "本机" : source.name
                let updated = Date(timeIntervalSince1970: task.updatedAt)
                let row = taskSnapshot(task, id: id, machine: machine)
                let health = states[RemoteActivityController.connectionKey(source.id, provider: task.provider)] ?? states[source.id]
                if (task.isActive && health != "实时连接") || task.state == "unknown" {
                    unknown.append(row)
                } else {
                    switch task.state {
                    case "running": running.append(row)
                    case "waiting": waiting.append(row)
                    case "completed":
                        completions.append(.init(
                            id: id,
                            isAnonymous: false,
                            projectName: row.projectName,
                            modelName: model,
                            effort: task.effort,
                            completedAt: updated,
                            duration: task.lifecycleComplete == false ? nil : task.updatedAt - task.startedAt, machineName: machine, tokenUsage: row.tokenUsage
                        ))
                    case "ended":
                        terminations.append(.init(
                            id: id,
                            isAnonymous: false,
                            projectName: row.projectName,
                            modelName: model,
                            effort: task.effort,
                            terminatedAt: updated,
                            duration: task.lifecycleComplete == false ? nil : task.updatedAt - task.startedAt, machineName: machine, tokenUsage: row.tokenUsage
                        ))
                    default: break
                    }
                }
            }
        }
        var result = CodexActivitySnapshot(
            waitingTasks: waiting.sorted { $0.stateChangedAt > $1.stateChangedAt },
            runningTasks: running.sorted { $0.stateChangedAt > $1.stateChangedAt },
            recentCompletions: completions.sorted { $0.completedAt > $1.completedAt },
            recentTerminations: terminations.sorted { $0.terminatedAt > $1.terminatedAt }
        )
        result.unconfirmedTasks = unknown.sorted { $0.stateChangedAt > $1.stateChangedAt }
        return result
    }

    static func taskSnapshot(_ task: RemoteActivityTask, id: UUID, machine: String? = nil) -> CodexActivityTaskSnapshot {
        CodexActivityTaskSnapshot(
            id: id, isAnonymous: false, latestEvent: latestEvent(task),
            projectName: task.project.isEmpty ? nil : task.project, modelName: task.modelName,
            effort: task.effort, toolName: readableToolName(task.toolName),
            startedAt: Date(timeIntervalSince1970: task.startedAt),
            stateChangedAt: Date(timeIntervalSince1970: task.stateChangedAt ?? task.updatedAt),
            showsPreciseDuration: task.lifecycleComplete != false, activeSubagentCount: task.activeSubagentCount,
            machineName: machine, tokenUsage: task.tokenUsageComplete == false ? nil : task.tokenUsage,
            stageTitle: stageTitle(task), recentEvent: recentEventTitle(task.recentEvent),
            planCompleted: task.planCompleted, planTotal: task.planTotal,
            pendingInputCount: task.pendingInputCount, hasBlockingInputRequest: task.hasBlockingInputRequest
        )
    }

    private static func stageTitle(_ task: RemoteActivityTask) -> String? {
        switch task.stage {
        case "processing": String(localized: "activity.stage.processing", defaultValue: "处理中")
        case "thinking": String(localized: "activity.event.thinking")
        case "answering", "replying": String(localized: "activity.stage.answering", defaultValue: "正在回复")
        case "tool":
            readableToolName(task.toolName).map { String(localized: "activity.event.using-named-tool", defaultValue: "\($0)") }
                ?? String(localized: "activity.event.using-tool")
        case "compacting": String(localized: "activity.event.compacting-context")
        case "waiting-approval": String(localized: "activity.status.waiting-for-approval")
        case "waiting-input": String(localized: "activity.stage.waiting-input", defaultValue: "等待回应")
        case "recovering-auth": String(localized: "activity.stage.recovering-auth", defaultValue: "恢复登录")
        case "retrying": String(localized: "activity.stage.retrying", defaultValue: "正在重试")
        case "agent-waiting": String(localized: "activity.stage.agent-waiting", defaultValue: "子任务运行中")
        default: nil
        }
    }

    private static func readableToolName(_ name: String?) -> String? {
        switch name {
        case "commandExecution": String(localized: "activity.tool.terminal", defaultValue: "终端")
        case "fileChange": String(localized: "activity.tool.files", defaultValue: "文件修改")
        case "webSearch": String(localized: "activity.tool.search", defaultValue: "联网搜索")
        case "mcpToolCall", "dynamicToolCall", "collabAgentToolCall": nil
        default: name
        }
    }

    private static func recentEventTitle(_ event: String?) -> String? {
        switch event {
        case "tool-completed": String(localized: "activity.event.tool-completed")
        case "tool-failed": String(localized: "activity.recent.tool-failed", defaultValue: "工具调用失败")
        case "agent-started": String(localized: "activity.event.starting-subagent")
        case "agent-completed": String(localized: "activity.event.subagent-completed")
        case "agent-interrupted": String(localized: "activity.recent.agent-interrupted", defaultValue: "子任务已中断")
        case "agent-failed": String(localized: "activity.recent.agent-failed", defaultValue: "子任务执行失败")
        default: nil
        }
    }

    static func latestEvent(_ task: RemoteActivityTask) -> CodexActivityEvent {
        if task.state == "waiting" {
            return .approvalRequested
        }
        switch task.eventName {
        case "PreToolUse": return .toolStarted
        case "PostToolUse": return .toolFinished
        case "PostToolUseFailure": return .toolFailed
        case "Stop": return .stopRequested
        case "PreCompact": return .compactionStarted
        case "PostCompact": return .compactionFinished
        case "SubagentStart": return .subagentStarted
        case "SubagentStop": return .subagentFinished
        default: return .promptSubmitted
        }
    }

    static func taskID(source: String, task: String, startedAt: TimeInterval) -> UUID {
        let bytes = Array(SHA256.hash(data: Data("\(source)\u{0}\(task)\u{0}\(startedAt)".utf8)).prefix(16))
        return UUID(uuid: (
            bytes[0],
            bytes[1],
            bytes[2],
            bytes[3],
            bytes[4],
            bytes[5],
            bytes[6],
            bytes[7],
            bytes[8],
            bytes[9],
            bytes[10],
            bytes[11],
            bytes[12],
            bytes[13],
            bytes[14],
            bytes[15]
        ))
    }
}
