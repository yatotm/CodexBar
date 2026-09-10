import SwiftUI

/// 宿主窗口与内容各接收一次目标高度, 不逐帧反向修改 AppKit 布局
struct UsageReveal<Content: View>: View {
    let isExpanded: Bool
    var animatesContent = true
    @ViewBuilder let content: () -> Content
    @State private var naturalHeight: CGFloat = 0

    var body: some View {
        content()
            .opacity(isExpanded ? 1 : 0)
            .transaction { $0.animation = nil }
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { naturalHeight = $0 }
            .clipShape(UsageTopReveal(height: isExpanded ? naturalHeight : 0))
            .frame(height: isExpanded ? naturalHeight : 0, alignment: .top)
            .animation(animatesContent ? .codexStatus : nil, value: isExpanded)
            .allowsHitTesting(isExpanded)
            .accessibilityHidden(!isExpanded)
    }
}

private struct UsageTopReveal: Shape {
    var height: CGFloat
    var animatableData: CGFloat {
        get { height }
        set { height = newValue }
    }

    func path(in rect: CGRect) -> Path {
        Path(CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: max(0, min(rect.height, height))))
    }
}

struct UsageDisclosure<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content
    @State private var isExpanded = false

    var body: some View {
        VStack(spacing: 0) {
            Button { isExpanded.toggle() } label: {
                HStack(spacing: 6) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .frame(width: 10, height: 10)
                        .transaction { $0.animation = nil
                            $0.disablesAnimations = true
                        }
                    Text(title)
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
                .contentShape(Rectangle())
                .transaction { $0.animation = nil }
            }
            .buttonStyle(.plain)
            .accessibilityValue(isExpanded ? "已展开" : "已收起")
            UsageReveal(isExpanded: isExpanded) { content().padding(.top, 8) }
        }
    }
}
