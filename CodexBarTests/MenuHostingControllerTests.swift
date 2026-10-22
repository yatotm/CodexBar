import AppKit
import SwiftUI
import Testing

struct MenuHostingControllerTests {
    @Test func initialAndUpdatedSizesUseWholePointsWithoutMovingContent() throws {
        let controller = MenuHostingController()
        controller.install(AnyView(Color.clear.frame(width: 200.25, height: 41.5)))
        #expect(controller.contentSize.height == 42)
        controller.resizeContent(to: CGSize(width: 220.25, height: 97.125))
        let contentView = try #require(controller.children.first?.view)
        #expect(controller.contentSize == CGSize(width: 221, height: 98))
        #expect(contentView.frame == CGRect(origin: .zero, size: controller.contentSize))

        controller.view.setFrameSize(CGSize(width: 221, height: 40))
        controller.view.layoutSubtreeIfNeeded()
        #expect(contentView.frame.origin == .zero)
        #expect(contentView.frame.height == 98)
        controller.resizeContent(to: CGSize(width: 221, height: 60.5))
        #expect(contentView.frame.origin == .zero)
        #expect(contentView.frame.height == 61)
    }

    @Test func invalidMeasurementsDoNotCorruptTheCurrentFrame() {
        let controller = MenuHostingController()
        controller.resizeContent(to: CGSize(width: 400, height: 100))
        for measurement in [CGSize(width: 400, height: 0), CGSize(width: 400, height: CGFloat.nan), CGSize(width: CGFloat.infinity, height: 100)] {
            controller.resizeContent(to: measurement)
            #expect(controller.contentSize == CGSize(width: 400, height: 100))
        }
    }
}
