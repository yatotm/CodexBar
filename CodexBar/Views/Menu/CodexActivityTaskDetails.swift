import Foundation

nonisolated enum CodexActivityTaskDetails {
    static func components(for task: CodexActivityTaskSnapshot, now: Date, isWaiting: Bool) -> [String] {
        var result = isWaiting
            ? CodexActivityDisplayFormat.waitingDetailComponents(for: task, now: now)
            : CodexActivityDisplayFormat.runningDetailComponents(for: task, now: now)
        if let stage = normalized(task.stageTitle) {
            if isWaiting {
                result[0] = stage
            } else {
                result[1] = stage
                result.swapAt(0, 1)
            }
        }

        var supplements: [String] = []
        if let completed = task.planCompleted, let total = task.planTotal, total > 0, completed >= 0, completed <= total {
            supplements.append(String(localized: "activity.summary.plan-progress", defaultValue: "计划 \(completed, specifier: "%lld")/\(total, specifier: "%lld")"))
        }
        if let count = task.pendingInputCount, count > 0 {
            supplements.append(String(localized: "activity.summary.pending-input-count", defaultValue: "待回应 \(count, specifier: "%lld")"))
        }
        if let count = task.activeSubagentCount, count > 0 {
            supplements.append(String(localized: "activity.summary.subagent-count", defaultValue: "\(count, specifier: "%lld")"))
        }
        result.insert(contentsOf: supplements, at: min(1, result.count))
        return result
    }

    static func help(for task: CodexActivityTaskSnapshot, now: Date, isWaiting: Bool) -> String {
        let detail = components(for: task, now: now, isWaiting: isWaiting).joined(separator: " • ")
        guard let recent = normalized(task.recentEvent) else { return detail }
        return detail + "\n" + recent
    }

    private static func normalized(_ text: String?) -> String? {
        guard let text else { return nil }
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
