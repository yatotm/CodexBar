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
        window.title = "用量中心"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.contentMinSize = NSSize(width: 900, height: 600)
        window.setContentSize(NSSize(width: 1040, height: 720))
        return window
    }
}
