import AppKit
import SwiftUI

@MainActor
final class UsageCenterWindowController: HostingWindowController {
    private let viewModel: UsageCenterViewModel

    init(viewModel: UsageCenterViewModel, screenProvider: @escaping () -> NSScreen?) {
        self.viewModel = viewModel
        super.init(screenProvider: screenProvider)
    }

    override func makeWindow() -> NSWindow {
        let controller = NSHostingController(rootView: UsageCenterView(viewModel: viewModel))
        let window = AuxiliaryHostingWindow(contentViewController: controller)
        window.title = "控制中心"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = false
        window.backgroundColor = .windowBackgroundColor
        window.contentMinSize = NSSize(width: 980, height: 660)
        window.setContentSize(NSSize(width: 1140, height: 760))
        return window
    }
}
