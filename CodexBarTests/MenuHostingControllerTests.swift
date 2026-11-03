import AppKit
import Combine
import SwiftUI
import Testing

struct MenuHostingControllerTests {
    @Test func dynamicContentMeasuresNaturallyAndStaysAtTopOfOldViewport() async throws {
        let model = MenuSizingProbeModel()
        let controller = MenuHostingController()
        let content = MenuSizingProbe(model: model)
            .frame(width: CodexStatusMenuView.menuWidth)
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGSize.self) { $0.size } action: { model.naturalSize = $0 }
        controller.install(AnyView(content))
        #expect(controller.contentSize.height == 327)
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: controller.contentSize), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        defer { window.close() }

        for (rows, height) in [(3, 327.0), (5, 487.0), (2, 247.0), (6, 567.0)] {
            model.rows = rows
            try await settle(controller)
            #expect(abs(model.naturalSize.height - height) < 0.001)
            #expect(abs(try #require(model.topFrame).minY - 12) < 0.001)
            #expect(abs(try #require(model.bottomFrame).maxY - (height - 12)) < 0.001)

            controller.resizeContent(to: model.naturalSize)
            window.setContentSize(controller.contentSize)
            try await settle(controller)
            #expect(abs(try #require(model.topFrame).minY - 12) < 0.001)
            #expect(try #require(model.bottomFrame).maxY <= controller.contentSize.height)
        }
    }

    private func settle(_ controller: MenuHostingController) async throws {
        for _ in 0 ..< 5 {
            controller.view.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(10))
        }
    }

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

private final class MenuSizingProbeModel: ObservableObject {
    @Published var rows = 3
    var naturalSize = CGSize.zero
    var topFrame: CGRect?
    var bottomFrame: CGRect?
}

private struct MenuSizingProbe: View {
    let model: MenuSizingProbeModel

    var body: some View {
        VStack(spacing: 10) {
            Text("top").frame(height: 25)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { model.topFrame = $0 }
            MenuSizingProbeRows(model: model)
            Text("bottom").frame(height: 28)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { model.bottomFrame = $0 }
        }
        .padding(12)
    }
}

private struct MenuSizingProbeRows: View {
    @ObservedObject var model: MenuSizingProbeModel

    var body: some View {
        ForEach(0 ..< model.rows, id: \.self) { _ in Color.blue.frame(height: 70) }
    }
}
