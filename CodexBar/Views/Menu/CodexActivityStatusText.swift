import AppKit
import Combine
import SwiftUI

struct CodexActivityStatusText: View {
    enum Effect: Equatable {
        case none
        case shimmer(taskID: UUID, event: CodexActivityEvent, toolName: String?)
        case ionizing(taskID: UUID)
    }

    let text: String
    let tint: Color
    let effect: Effect
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isInViewport = true

    private var visibleEffect: Effect {
        reduceMotion || !isInViewport ? .none : effect
    }

    var body: some View {
        Text(text)
            .foregroundStyle(tint)
            .overlay {
                if case .shimmer = visibleEffect {
                    ActivityStatusShimmer(text: text, phase: visibleEffect)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .font(.caption2)
            .lineLimit(1)
            .truncationMode(.tail)
            .anchorPreference(key: ActivityIonizationSourceKey.self, value: .bounds) { bounds in
                if case let .ionizing(taskID) = visibleEffect {
                    return [ActivityIonizationSource(taskID: taskID, bounds: bounds)]
                }
                return []
            }
            .onScrollVisibilityChange(threshold: 0.01) { isInViewport = $0 }
    }
}

extension View {
    func activityStatusParticles(cornerRadius: CGFloat) -> some View {
        // 在玻璃背景之前应用, 让粒子位于背景之上和文字之下
        backgroundPreferenceValue(ActivityIonizationSourceKey.self) { sources in
            GeometryReader { geometry in
                let panelBounds = CGRect(origin: .zero, size: geometry.size)
                let emitters = sources.compactMap { source -> ActivityIonizationEmitter? in
                    let bounds = geometry[source.bounds]
                    let viewport = source.viewport.map { geometry[$0] } ?? panelBounds
                    guard bounds.intersects(viewport), bounds.intersects(panelBounds) else { return nil }
                    return ActivityIonizationEmitter(taskID: source.taskID, bounds: bounds)
                }
                if !emitters.isEmpty {
                    ActivityIonizationParticles(emitters: emitters)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .allowsHitTesting(false)
        }
    }

    func activityStatusParticleViewport() -> some View {
        transformAnchorPreference(key: ActivityIonizationSourceKey.self, value: .bounds) { sources, viewport in
            for index in sources.indices {
                sources[index].viewport = viewport
            }
        }
    }
}

private struct ActivityIonizationSource {
    let taskID: UUID
    let bounds: Anchor<CGRect>
    var viewport: Anchor<CGRect>?
}

private struct ActivityIonizationEmitter {
    let bounds: CGRect
    let seed: Int

    init(taskID: UUID, bounds: CGRect) {
        self.bounds = bounds
        // 随机序列只依赖任务身份, 滚动过滤和任务增删不改变其他任务的粒子相位
        seed = Int(UInt32(truncatingIfNeeded: taskID.hashValue)) * 12
    }
}

private struct ActivityIonizationSourceKey: PreferenceKey {
    static var defaultValue: [ActivityIonizationSource] {
        []
    }

    static func reduce(value: inout [ActivityIonizationSource], nextValue: () -> [ActivityIonizationSource]) {
        value.append(contentsOf: nextValue())
    }
}

private struct ActivityIonizationParticles: View {
    let emitters: [ActivityIonizationEmitter]
    @State private var startedAt = Date()
    @State private var isPlaying = true

    var body: some View {
        // 面板共用一条粒子时间线, 发射源为空时由宿主移除; 不受任务行和滚动容器裁剪
        Group {
            if isPlaying {
                particles
            }
        }
        .task(id: emitters.map(\.seed).sorted()) {
            startedAt = Date()
            isPlaying = true
            do {
                try await Task.sleep(for: .seconds(3))
                try Task.checkCancellation()
                isPlaying = false
            } catch {}
        }
    }

    private var particles: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { timeline in
            let elapsed = timeline.date.timeIntervalSince(startedAt)
            Canvas { context, _ in
                context.addFilter(.shadow(color: .orange.opacity(0.9), radius: 4.0 / 3))
                context.addFilter(.shadow(color: .orange.opacity(0.5), radius: 4))
                for emitter in emitters {
                    for index in 0 ..< 12 {
                        let seed = emitter.seed + index
                        let age = elapsed / 1.1 + ActivityIonizationNoise.value(seed, seed: 7331)
                        let life = age - floor(age)
                        let angle = ActivityIonizationNoise.value(seed, seed: Int(floor(age))) * 2 * .pi
                        let origin = (ActivityIonizationNoise.value(seed, seed: 3) - 0.5) * 140
                        let x = emitter.bounds.midX + origin + cos(angle) * 40 * life
                        let y = emitter.bounds.midY + sin(angle) * 30 * life
                        var particleContext = context
                        particleContext.opacity = 1 - life
                        particleContext.fill(
                            Path(ellipseIn: CGRect(x: x - 1.5, y: y - 1.5, width: 3, height: 3)),
                            with: .color(.orange)
                        )
                    }
                }
            }
        }
    }
}

private enum ActivityIonizationNoise {
    static func value(_ index: Int, seed: Int) -> Double {
        let value = sin(Double(index + 1) * 127.1 + Double(seed) * 311.7) * 43758.5453
        return value - floor(value)
    }
}

private struct ActivityStatusShimmer: NSViewRepresentable {
    let text: String
    let phase: CodexActivityStatusText.Effect

    func makeNSView(context _: Context) -> ActivityStatusShimmerView {
        ActivityStatusShimmerView()
    }

    func updateNSView(_ view: ActivityStatusShimmerView, context _: Context) {
        view.update(text: text, phase: phase)
    }

    static func dismantleNSView(_ view: ActivityStatusShimmerView, coordinator _: ()) {
        view.stop()
    }
}

/// 文字遮罩仅在内容或尺寸变化时重建, 扫光由合成器移动独立的小图层
final class ActivityStatusShimmerView: NSView {
    private let maskedLayer = CALayer()
    private let textMask = CALayer()
    private let gradient = CAGradientLayer()
    private var windowObservation: AnyCancellable?
    private var text = ""
    private var phase: CodexActivityStatusText.Effect?
    private var renderedMask: MaskKey?
    private var animationStartedAt: CFTimeInterval?

    private struct MaskKey: Equatable {
        let text: String
        let size: CGSize
        let scale: CGFloat
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.addSublayer(maskedLayer)
        maskedLayer.mask = textMask
        maskedLayer.addSublayer(gradient)
        gradient.colors = [NSColor.clear.cgColor, NSColor.white.cgColor, NSColor.clear.cgColor]
        gradient.startPoint = CGPoint(x: 0, y: 0.5)
        gradient.endPoint = CGPoint(x: 1, y: 0.5)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    override func hitTest(_: NSPoint) -> NSView? {
        nil
    }

    func update(text: String, phase: CodexActivityStatusText.Effect) {
        if self.phase != phase {
            stop()
            self.phase = phase
        }
        self.text = text
        refreshAnimation()
    }

    override func layout() {
        super.layout()
        refreshAnimation()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        windowObservation = nil
        if let window {
            windowObservation = NotificationCenter.default.publisher(for: NSWindow.didChangeOcclusionStateNotification, object: window)
                .sink { [weak self] _ in
                    MainActor.assumeIsolated { self?.refreshAnimation() }
                }
        }
        refreshAnimation()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        refreshAnimation()
    }

    override func viewDidHide() {
        super.viewDidHide()
        refreshAnimation()
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        refreshAnimation()
    }

    func stop() {
        gradient.removeAnimation(forKey: "sweep")
        maskedLayer.isHidden = true
        animationStartedAt = nil
    }

    private func refreshAnimation() {
        updateAnimation(isVisible: window?.occlusionState.contains(.visible) == true
            && !isHiddenOrHasHiddenAncestor && !visibleRect.isEmpty)
    }

    func updateAnimation(isVisible: Bool, now: CFTimeInterval = CACurrentMediaTime()) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        guard isVisible, !text.isEmpty, bounds.width > 0, bounds.height > 0 else {
            stop()
            return
        }
        // 经过时间和 Token 更新不能重播已结束的扫光, 新阶段或重新显示时才重置
        if let animationStartedAt, now - animationStartedAt >= 4.4 {
            gradient.removeAnimation(forKey: "sweep")
            maskedLayer.isHidden = true
            return
        }

        let key = MaskKey(text: text, size: bounds.size, scale: window?.backingScaleFactor ?? 1)
        if renderedMask != key {
            let renderer = ImageRenderer(content: Text(text)
                .font(.caption2)
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: key.size.width, height: key.size.height, alignment: .leading))
            renderer.scale = key.scale
            guard let image = renderer.cgImage else {
                stop()
                return
            }
            if renderedMask?.size != key.size {
                gradient.removeAnimation(forKey: "sweep")
            }
            renderedMask = key
            maskedLayer.frame = bounds
            textMask.frame = maskedLayer.bounds
            textMask.contentsScale = key.scale
            textMask.contents = image
            gradient.frame = CGRect(x: 0, y: 0, width: bounds.width * 0.4, height: bounds.height)
            gradient.transform = CATransform3DMakeTranslation(bounds.width, 0, 0)
        }

        maskedLayer.isHidden = false
        guard gradient.animation(forKey: "sweep") == nil else { return }
        let animation = CABasicAnimation(keyPath: "transform.translation.x")
        animation.fromValue = -gradient.bounds.width
        animation.toValue = bounds.width
        animation.duration = 2.2
        animation.repeatCount = 2
        animation.timingFunction = CAMediaTimingFunction(name: .linear)
        animation.preferredFrameRateRange = CAFrameRateRange(minimum: 20, maximum: 30, preferred: 30)
        let start = animationStartedAt ?? now
        animationStartedAt = start
        animation.beginTime = gradient.convertTime(start, from: nil)
        gradient.add(animation, forKey: "sweep")
    }
}
