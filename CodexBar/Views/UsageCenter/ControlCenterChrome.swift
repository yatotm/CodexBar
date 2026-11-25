import AppKit
import SwiftUI

enum ControlCenterPalette {
    static let codex = Color(hex: 0x2563EB)
    static let claude = Color(hex: 0xD97757)
    static let gemini = Color(hex: 0x6366F1)

    static func providerAccent(_ provider: String) -> Color {
        switch provider.lowercased() {
        case "codex": codex
        case "claude": claude
        case "gemini": gemini
        default: .accentColor
        }
    }

    static func canvasBackground(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(hex: 0x101217) : Color(hex: 0xF4F5F8)
    }

    static func cardBackground(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(hex: 0x181B22) : .white
    }

    static func insetBackground(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(hex: 0x13161C) : Color(hex: 0xF7F8FA)
    }

    static func pillTrack(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.06) : Color.black.opacity(0.048)
    }

    static func pillActiveFill(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(hex: 0x262B36) : .white
    }

    static func cardBorder(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.075) : Color.black.opacity(0.065)
    }

    static func subtleBorder(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.055) : Color.black.opacity(0.045)
    }
}

/// 原生毛玻璃侧边栏宿主, 由系统窗口合成器硬件加速而不在滚动层重复模糊
struct ControlCenterVibrancySidebar: NSViewRepresentable {
    func makeNSView(context _: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_: NSVisualEffectView, context _: Context) {}
}

struct ControlCenterPillOption<Value: Hashable>: Identifiable {
    let value: Value
    let title: String
    var dotColor: Color?

    var id: Value {
        value
    }
}

struct ControlCenterPillPicker<Value: Hashable>: View {
    let options: [ControlCenterPillOption<Value>]
    @Binding var selection: Value
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 3) {
            ForEach(options) { option in
                pillButton(option)
            }
        }
        .padding(3)
        .background(ControlCenterPalette.pillTrack(colorScheme), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(ControlCenterPalette.subtleBorder(colorScheme), lineWidth: 0.7)
        }
    }

    private func pillButton(_ option: ControlCenterPillOption<Value>) -> some View {
        let isSelected = selection == option.value
        return Button {
            withAnimation(.easeOut(duration: 0.14)) {
                selection = option.value
            }
        } label: {
            HStack(spacing: 5) {
                if let dot = option.dotColor {
                    Circle()
                        .fill(dot)
                        .frame(width: 6, height: 6)
                        .opacity(isSelected ? 1.0 : 0.65)
                }
                Text(option.title)
                    .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
                    .foregroundStyle(isSelected ? .primary : .secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 6.5, style: .continuous)
                        .fill(ControlCenterPalette.pillActiveFill(colorScheme))
                        .shadow(color: .black.opacity(colorScheme == .dark ? 0.28 : 0.07), radius: 2, y: 1)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct ControlCenterStatusBadge: View {
    let title: String
    let color: Color

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(color)
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(color.opacity(0.12), in: Capsule(style: .continuous))
    }
}

struct ControlCenterSectionHeader<Trailing: View>: View {
    let title: String
    var subtitle: String?
    var symbol: String?
    var tint: Color = .accentColor
    @ViewBuilder var trailing: () -> Trailing

    init(
        title: String,
        subtitle: String? = nil,
        symbol: String? = nil,
        tint: Color = .accentColor,
        @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() }
    ) {
        self.title = title
        self.subtitle = subtitle
        self.symbol = symbol
        self.tint = tint
        self.trailing = trailing
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 26, height: 26)
                    .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.primary)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            trailing()
        }
    }
}

struct ControlCenterBentoMetricCard: View {
    let title: String
    let value: String
    let detail: String
    let symbol: String
    let tint: Color
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: symbol)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 24, height: 24)
                    .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            Text(value)
                .font(.system(size: 23, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Text(detail)
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ControlCenterPalette.cardBackground(colorScheme), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(ControlCenterPalette.cardBorder(colorScheme), lineWidth: 0.8)
        }
    }
}

struct ControlCenterIconButton: View {
    let symbol: String
    var helpText = ""
    var isDisabled = false
    let action: () -> Void
    @State private var isHovered = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(isHovered ? .primary : .secondary)
                .frame(width: 28, height: 28)
                .background(
                    isHovered ? ControlCenterPalette.pillTrack(colorScheme) : .clear,
                    in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .onHover { isHovered = $0 }
        .help(helpText)
    }
}

struct ControlCenterCardModifier: ViewModifier {
    var cornerRadius: CGFloat = 13
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content
            .background(
                ControlCenterPalette.cardBackground(colorScheme),
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(ControlCenterPalette.cardBorder(colorScheme), lineWidth: 0.8)
                    .allowsHitTesting(false)
            }
    }
}

struct ControlCenterInsetModifier: ViewModifier {
    var cornerRadius: CGFloat = 10
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content
            .background(
                ControlCenterPalette.insetBackground(colorScheme),
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(ControlCenterPalette.subtleBorder(colorScheme), lineWidth: 0.8)
                    .allowsHitTesting(false)
            }
    }
}

extension View {
    func usageCenterCard(cornerRadius: CGFloat = 13) -> some View {
        modifier(ControlCenterCardModifier(cornerRadius: cornerRadius))
    }

    func usageCenterInset(cornerRadius: CGFloat = 10) -> some View {
        modifier(ControlCenterInsetModifier(cornerRadius: cornerRadius))
    }
}
