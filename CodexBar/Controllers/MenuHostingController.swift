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
        let hosting = NSHostingController(rootView: root)
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

private final class TopPinnedMenuView: NSView {
    override var isFlipped: Bool {
        true
    }
}
