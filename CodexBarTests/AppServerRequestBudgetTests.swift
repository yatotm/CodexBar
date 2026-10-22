import Foundation
import Testing

struct AppServerRequestBudgetTests {
    @Test func expiredBudgetRejectsBeforeOperation() {
        let budget = AppServerRequestBudget(deadline: Date().addingTimeInterval(-1))
        #expect(throws: CodexStatusError.self) { try budget.check() }
    }

    @Test func constrainedBudgetCannotExtendMonotonicDeadline() {
        let original = AppServerRequestBudget(deadline: Date().addingTimeInterval(60))
        let movedClock = Date().addingTimeInterval(-3600)
        let constrained = original.constrained(to: original.wallDeadline, now: movedClock)
        #expect(constrained.deadline <= original.deadline)
        #expect(constrained.wallDeadline == original.wallDeadline)
    }

    @Test func earlierDeadlineConstrainsWallAndMonotonicBudget() {
        let now = Date()
        let original = AppServerRequestBudget(deadline: now.addingTimeInterval(60))
        let cutoff = now.addingTimeInterval(5)
        let constrained = original.constrained(to: cutoff, now: now)
        #expect(constrained.wallDeadline == cutoff)
        #expect(constrained.deadline < original.deadline)
    }

    @Test func taskLocalDeadlineIsCheckedAtRequestBoundary() throws {
        let budget = AppServerRequestBudget(deadline: Date().addingTimeInterval(-1))
        AppServerRequestBudget.$current.withValue(budget) {
            #expect(throws: CodexStatusError.self) { try AppServerRequestBudget.checkCurrent() }
        }
        try AppServerRequestBudget.checkCurrent()
    }

    @Test func cancellationIsRejectedEvenWithoutDeadline() async {
        let task = Task { () -> Bool in
            withUnsafeCurrentTask { $0?.cancel() }
            do { try AppServerRequestBudget.checkCurrent() } catch is CancellationError { return true } catch {}
            return false
        }
        #expect(await task.value)
    }
}
