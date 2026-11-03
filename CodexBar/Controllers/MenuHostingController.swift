import AppKit
import SwiftUI

/// 弹窗只改变外层裁剪区域, SwiftUI 内容保持完整高度并钉在顶部
@MainActor
final class MenuHostingController: NSViewController {
    private var hosting: NSHostingController<AnyView>?
    private(set) var contentSize = CGSize(width: CodexStatusMenuView.menuWidth, height: 420)

    override func loadView() {
        let container = TopPinnedMenuView()
        container.autoresizesSubviews = false
        container.wantsLayer = true
        container.layer?.masksToBounds = true
        view = container
    }

    func install(_ root: AnyView) {
        let hosting = NSHostingController(rootView: AnyView(TopPinnedMenuContent { root }))
        hosting.sizingOptions = []
        hosting.safeAreaRegions = []
        self.hosting = hosting
        addChild(hosting)
        view.addSubview(hosting.view)
        hosting.view.autoresizingMask = []
        resizeContent(to: hosting.sizeThatFits(in: CGSize(width: CodexStatusMenuView.menuWidth, height: 0)))
        view.setFrameSize(contentSize)
    }

    func resizeContent(to size: CGSize) {
        guard size.width.isFinite, size.height.isFinite, size.height > 0 else { return }
        let size = CGSize(width: ceil(size.width), height: ceil(size.height))
        contentSize = size
        // NSPopover 会为内容视图建立尺寸动画, 内层不能继承同一动画上下移动
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            context.allowsImplicitAnimation = false
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            hosting?.view.frame = CGRect(origin: .zero, size: size)
            CATransaction.commit()
        }
    }
}

/// 内容按自然高度测量, 宿主仍使用窗口当前高度, 避免新内容在旧窗口内居中溢出
private struct TopPinnedMenuContent: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) -> CGSize {
        guard let child = subviews.first else { return .zero }
        let natural = child.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
        // 安装时的零高度提议用于测量, 不能把零当成真实窗口高度
        let height = proposal.height.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        return CGSize(width: natural.width, height: height ?? ceil(natural.height))
    }

    func placeSubviews(in bounds: CGRect, proposal _: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
        subviews.first?.place(
            at: bounds.origin, anchor: .topLeading,
            proposal: ProposedViewSize(width: bounds.width, height: nil)
        )
    }
}

private final class TopPinnedMenuView: NSView {
    override var isFlipped: Bool {
        true
    }
}
