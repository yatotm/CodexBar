import SwiftUI

enum HelperFeatureConfirmation: Identifiable {
    case autoReset
    case keepAlive

    var id: Self {
        self
    }

    func alert(
        helperStatus: KeepAliveController.HelperStatus,
        manualKeepAlive: Bool = false,
        onConfirm: @escaping () -> Void
    ) -> Alert {
        Alert(
            title: title,
            message: Text(verbatim: message(helperStatus: helperStatus, manualKeepAlive: manualKeepAlive)),
            primaryButton: .destructive(Text("common.action.enable"), action: onConfirm),
            secondaryButton: .cancel(Text("common.action.cancel"))
        )
    }

    private var title: Text {
        switch self {
        case .autoReset:
            Text("auto-reset.confirmation.title")
        case .keepAlive:
            Text("keep-alive.confirmation.title")
        }
    }

    private var details: String {
        switch self {
        case .autoReset:
            String(localized: "auto-reset.confirmation.message")
        case .keepAlive:
            String(localized: "keep-alive.confirmation.message")
        }
    }

    private func message(helperStatus: KeepAliveController.HelperStatus, manualKeepAlive: Bool) -> String {
        let details = self == .keepAlive && manualKeepAlive
            ? "开启后 Mac 将保持唤醒, 包括合盖时; 关闭开关, 退出 App 或触发时长及低电量保护后恢复原有睡眠设置"
            : details
        return switch helperStatus {
        case .notRegistered, .notFound:
            "\(String(localized: "helper.status.install-and-authorize"))\n\(details)"
        case .requiresApproval:
            "\(String(localized: "helper.status.installed-needs-authorization"))\n\(details)"
        case .enabled:
            details
        }
    }
}
