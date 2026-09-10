import AppKit
import SwiftUI

enum CodexStatusMenuView {
    static let menuWidth: CGFloat = 492
}

@main
struct UsageMenuLayoutSmoke {
    static func main() {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let controller = MenuHostingController()
        controller.install(AnyView(VStack(alignment: .leading) {
            Text("本机")
            Text("设备二")
            Text("设备三")
        }.frame(width: 492, height: 160, alignment: .topLeading)))
        controller.resizeContent(to: CGSize(width: 492, height: 160))
        let child = controller.view.subviews[0]
        for height in [20.0, 45.0, 80.0, 120.0, 160.0, 90.0, 30.0] {
            controller.view.setFrameSize(CGSize(width: 492, height: height))
            controller.view.layoutSubtreeIfNeeded()
            precondition(controller.view.isFlipped, "裁剪容器以顶部为原点")
            precondition(child.frame.origin == .zero, "窗口展开或收起不得移动内容原点")
            precondition(child.frame.height == 160, "窗口动画不得压缩设备列表高度")
            precondition(controller.view.layer?.masksToBounds == true, "未展开部分必须被窗口容器裁剪")
        }
        print("Menu content stays pinned to the top at every tested host height")
    }
}
