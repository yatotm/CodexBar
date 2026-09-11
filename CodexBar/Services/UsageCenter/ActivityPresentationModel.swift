import Combine
import CryptoKit
import Foundation

/// 只合并展示, 本机通知与防睡眠仍由原始监控快照驱动
@MainActor
final class ActivityPresentationModel: ObservableObject {
    @Published private(set) var snapshot = CodexActivitySnapshot.empty
    private var observation: AnyCancellable?
    private var expirationTask: Task<Void, Never>?

    init(local: CodexActivityMonitor, usage: UsageCenterViewModel) {
        let remote = usage.remoteActivity
        observation = Publishers.CombineLatest4(local.$snapshot, remote.$tasks, remote.$states, remote.$enabledSourceIDs)
            .combineLatest(usage.$sources, usage.$menuScope)
            .sink { [weak self] values, sources, scope in
                self?.update(local: values.0, tasks: values.1, states: values.2, enabled: values.3, sources: sources, scope: scope)
            }
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
        let result = Self.merge(local: local, tasks: tasks, states: states, enabled: enabled, sources: sources, scope: scope, now: now)
        if snapshot != result {
            snapshot = result
        }
        expirationTask?.cancel()
        expirationTask = nil
        let deadlines = tasks.values.flatMap(\.self).filter { $0.state == "completed" || $0.state == "ended" }
            .map { Date(timeIntervalSince1970: $0.updatedAt + CodexActivityRetention.recentHistory) }
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
                if task.state == "completed" || task.state == "ended" {
                    guard task.updatedAt > now.timeIntervalSince1970 - CodexActivityRetention.recentHistory else { continue }
                    // 旧采集器的孤立 SessionEnd 没有任务起点, 仅在展示层过滤
                    guard task.state != "ended" || task.updatedAt > task.startedAt else { continue }
                }
                let id = taskID(source: source.id, task: task.id)
                let model = task.modelName ?? "未知模型"
                let machine = source.transport == .local ? "本机" : source.name
                let updated = Date(timeIntervalSince1970: task.updatedAt)
                let row = CodexActivityTaskSnapshot(
                    id: id, isAnonymous: false, latestEvent: latestEvent(task),
                    projectName: task.project.isEmpty ? nil : task.project, modelName: model, effort: nil, toolName: task.toolName,
                    startedAt: Date(timeIntervalSince1970: task.startedAt), stateChangedAt: updated,
                    showsPreciseDuration: true, activeSubagentCount: task.activeSubagentCount, machineName: machine
                )
                if (task.isActive && states[source.id] != "实时连接") || task.state == "unknown" {
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
                            effort: nil,
                            completedAt: updated,
                            duration: task.updatedAt - task.startedAt, machineName: machine
                        ))
                    case "ended":
                        terminations.append(.init(
                            id: id,
                            isAnonymous: false,
                            projectName: row.projectName,
                            modelName: model,
                            effort: nil,
                            terminatedAt: updated,
                            duration: task.updatedAt - task.startedAt, machineName: machine
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
            recentTerminations: terminations.sorted { $0.terminatedAt > $1.terminatedAt },
            isCompletionHighlighted: scope != .claude && local.isCompletionHighlighted
        )
        result.unconfirmedTasks = unknown.sorted { $0.stateChangedAt > $1.stateChangedAt }
        return result
    }

    private static func latestEvent(_ task: RemoteActivityTask) -> CodexActivityEvent {
        if task.state == "waiting" {
            return .approvalRequested
        }
        switch task.eventName {
        case "PreToolUse": return .toolStarted
        case "PostToolUse": return .toolFinished
        case "PostToolUseFailure": return .toolFailed
        case "PreCompact": return .compactionStarted
        case "PostCompact": return .compactionFinished
        case "SubagentStart": return .subagentStarted
        case "SubagentStop": return .subagentFinished
        default: return .promptSubmitted
        }
    }

    private static func taskID(source: String, task: String) -> UUID {
        let bytes = Array(SHA256.hash(data: Data("\(source)\u{0}\(task)".utf8)).prefix(16))
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
