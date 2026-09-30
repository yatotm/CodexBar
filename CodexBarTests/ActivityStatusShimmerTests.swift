import AppKit
import QuartzCore
import Testing

struct ActivityStatusShimmerTests {
    private let phase = CodexActivityStatusText.Effect.shimmer(taskID: UUID(), event: .toolStarted, toolName: "Bash")

    @Test func unchangedContentReusesMaskAndAnimation() throws {
        let view = ActivityStatusShimmerView(frame: NSRect(x: 0, y: 0, width: 180, height: 16))
        view.update(text: "已运行 1分钟 • 调用工具 Bash", phase: phase)
        view.updateAnimation(isVisible: true)
        let masked = try #require(view.layer?.sublayers?.first)
        let mask = try #require(masked.mask)
        let image = try #require(mask.contents) as AnyObject
        let gradient = try #require(masked.sublayers?.first)
        let animation = try #require(gradient.animation(forKey: "sweep"))

        for _ in 0 ..< 20 {
            view.updateAnimation(isVisible: true)
        }
        #expect(masked.mask?.contents as AnyObject? === image)
        #expect(gradient.animation(forKey: "sweep")?.beginTime == animation.beginTime)
        #expect(mask.bounds.size == CGSize(width: 180, height: 16))
        #expect(gradient.bounds.width == 72)
        #expect(view.hitTest(.zero) == nil)
        view.stop()
    }

    @Test func hiddenAndEmptyTextRemoveContinuousAnimation() throws {
        let view = ActivityStatusShimmerView(frame: NSRect(x: 0, y: 0, width: 160, height: 16))
        view.update(text: "等待工具返回", phase: phase)
        view.updateAnimation(isVisible: true)
        let masked = try #require(view.layer?.sublayers?.first)
        let gradient = try #require(masked.sublayers?.first)
        #expect(gradient.animation(forKey: "sweep") != nil)
        view.updateAnimation(isVisible: false)
        #expect(gradient.animationKeys()?.isEmpty != false)
        #expect(masked.isHidden)
        view.updateAnimation(isVisible: true)
        #expect(gradient.animation(forKey: "sweep") != nil)
        view.update(text: "", phase: phase)
        view.updateAnimation(isVisible: true)
        #expect(gradient.animationKeys()?.isEmpty != false)
        #expect(masked.isHidden)
    }

    @Test func finishedSweepDoesNotRestartUntilRedisplayed() throws {
        let view = ActivityStatusShimmerView(frame: NSRect(x: 0, y: 0, width: 160, height: 16))
        view.update(text: "运行中", phase: phase)
        view.updateAnimation(isVisible: true, now: 100)
        let masked = try #require(view.layer?.sublayers?.first)
        let gradient = try #require(masked.sublayers?.first)
        view.updateAnimation(isVisible: true, now: 105)
        #expect(gradient.animation(forKey: "sweep") == nil)
        #expect(masked.isHidden)
        view.updateAnimation(isVisible: true, now: 120)
        #expect(gradient.animation(forKey: "sweep") == nil)
        view.updateAnimation(isVisible: false, now: 121)
        view.updateAnimation(isVisible: true, now: 122)
        #expect(gradient.animation(forKey: "sweep") != nil)
        view.stop()
    }
}
