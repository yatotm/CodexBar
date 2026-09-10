import Combine
import CryptoKit
import Foundation

/// 只合并展示, 本机通知与防睡眠仍由原始监控快照驱动
@MainActor
final class ActivityPresentationModel: ObservableObject {
    @Published private(set) var snapshot = CodexActivitySnapshot.empty
    private var observation: AnyCancellable?

    init(local: CodexActivityMonitor, usage: UsageCenterViewModel) {
        let remote = usage.remoteActivity
        observation = Publishers.CombineLatest4(local.$snapshot, remote.$tasks, remote.$states, remote.$enabledSourceIDs)
            .combineLatest(usage.$sources, usage.$menuScope)
            .sink { [weak self] values, sources, scope in
                let result = Self.merge(local: values.0, tasks: values.1, states: values.2, enabled: values.3, sources: sources, scope: scope)
                if self?.snapshot != result {
                    self?.snapshot = result
                }
            }
    }

    static func merge(
        local: CodexActivitySnapshot,
        tasks: [String: [RemoteActivityTask]],
        states: [String: String],
        enabled: Set<String>,
        sources: [UsageSource],
        scope: UsageMenuScope
    ) -> CodexActivitySnapshot {
        var waiting = [CodexActivityTaskSnapshot](), running = [CodexActivityTaskSnapshot](), unknown = [CodexActivityTaskSnapshot]()
        var completions = [CodexActivityCompletion](), terminations = [CodexActivityTermination]()
        if scope != .claude {
            waiting = local.waitingTasks.map { var task = $0
                task.modelName = displayModel(task.modelName ?? "未知模型", machine: "本机")
                return task
            }
            running = local.runningTasks.map { var task = $0
                task.modelName = displayModel(task.modelName ?? "未知模型", machine: "本机")
                return task
            }
            completions = local.recentCompletions.map { var task = $0
                task.modelName = displayModel(task.modelName ?? "未知模型", machine: "本机")
                return task
            }
            terminations = local.recentTerminations.map { var task = $0
                task.modelName = displayModel(task.modelName ?? "未知模型", machine: "本机")
                return task
            }
        }
        for source in sources where source.isEnabled && enabled.contains(source.id) {
            for task in tasks[source.id] ?? [] where scope == .all || scope.rawValue == task.provider {
                guard task.provider == "codex" ? source.includesCodex : source.includesClaude else { continue }
                guard task.provider != "codex" || source.transport != .local else { continue }
                let id = taskID(source: source.id, task: task.id)
                let model = displayModel(task.modelName ?? "未知模型", machine: source.transport == .local ? "本机" : source.name)
                let updated = Date(timeIntervalSince1970: task.updatedAt)
                let row = CodexActivityTaskSnapshot(
                    id: id, isAnonymous: false, latestEvent: task.state == "waiting" ? .approvalRequested : .promptSubmitted,
                    projectName: task.project.isEmpty ? nil : task.project, modelName: model, effort: nil, toolName: nil,
                    startedAt: Date(timeIntervalSince1970: task.startedAt), stateChangedAt: updated,
                    showsPreciseDuration: true, activeSubagentCount: nil
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
                            duration: task.updatedAt - task.startedAt
                        ))
                    case "ended":
                        terminations.append(.init(
                            id: id,
                            isAnonymous: false,
                            projectName: row.projectName,
                            modelName: model,
                            effort: nil,
                            terminatedAt: updated,
                            duration: task.updatedAt - task.startedAt
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

    private static func displayModel(_ model: String, machine: String) -> String {
        "\(model) · \(machine)"
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
