import Foundation
import os

/// 串行合并本地维护请求, 用户发起的重建优先于普通刷新
@MainActor
final class WorkflowMaintenanceScheduler {
    typealias RebuildCompletion = (Result<WorkflowDataRebuildSummary, Error>) -> Void
    typealias RebuildHandler = ([String], @escaping RebuildCompletion) -> Void

    private let viewModel: WorkflowViewModel
    private var isRunning = false
    private var pendingRebuild: RebuildRequest?
    private var pendingMaintenanceTrigger: LogTrigger?

    init(viewModel: WorkflowViewModel) {
        self.viewModel = viewModel
    }

    func requestMaintenance(trigger: LogTrigger) {
        pendingMaintenanceTrigger = pendingMaintenanceTrigger ?? trigger
        drain()
    }

    func requestRebuild(for dateKeys: [String], completion: @escaping RebuildCompletion) {
        pendingRebuild?.completion(.failure(CancellationError()))
        pendingRebuild = RebuildRequest(dateKeys: dateKeys, completion: completion)
        drain()
    }

    func clearPendingMaintenance() {
        pendingMaintenanceTrigger = nil
    }

    func cancel() {
        clearPendingMaintenance()
        pendingRebuild?.completion(.failure(CancellationError()))
        pendingRebuild = nil
    }

    private func drain() {
        guard !isRunning else { return }
        if let request = pendingRebuild {
            pendingRebuild = nil
            isRunning = true
            Task { @MainActor [weak self] in
                guard let self else { return }
                let result: Result<WorkflowDataRebuildSummary, Error>
                do {
                    result = try await .success(viewModel.rebuildData(for: request.dateKeys))
                } catch {
                    AppLog.workflow.error("数据重建失败: detail=\(error.localizedDescription, privacy: .public)")
                    result = .failure(error)
                }
                isRunning = false
                request.completion(result)
                drain()
            }
        } else if let trigger = pendingMaintenanceTrigger {
            pendingMaintenanceTrigger = nil
            isRunning = true
            let duration = LogDuration()
            Task { @MainActor [weak self] in
                guard let self else { return }
                let counts = await viewModel.refreshMaintenance()
                if let counts {
                    let details = LogFields.joined(
                        "trigger=\(trigger.rawValue)",
                        "idle=\(counts.idle)",
                        "dates=\(counts.dates)",
                        "range=\(counts.dateRange)",
                        "events=\(counts.events)",
                        "written=\(counts.written)",
                        "skipped=\(counts.skipped)",
                        "failed=\(counts.failed)",
                        "pruned=\(counts.pruned)",
                        "elapsed=\(duration.elapsed)"
                    )
                    AppLog.workflow.notice("统计刷新完成: \(details, privacy: .public)")
                }
                isRunning = false
                drain()
            }
        }
    }

    private struct RebuildRequest {
        let dateKeys: [String]
        let completion: RebuildCompletion
    }
}
