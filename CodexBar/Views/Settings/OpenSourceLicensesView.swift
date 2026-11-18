import SwiftUI

/// 从安装包读取与当前构建一起分发的许可文本
struct OpenSourceLicensesView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var selection = Document.notices
    @State private var content: String?

    private enum Document: String, CaseIterable {
        case notices = "OpenSourceNotices.txt"
        case project = "LICENSE"
        case sparkle = "Sparkle-LICENSE.txt"

        var label: String {
            switch self {
            case .notices: String(localized: "settings.licenses.attribution")
            case .project: "GPLv3"
            case .sparkle: "Sparkle"
            }
        }
    }

    var body: some View {
        VStack(spacing: 12) {
            Picker("settings.licenses.title", selection: $selection) {
                ForEach(Document.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            ScrollView {
                Text(verbatim: content ?? "")
                    .font(.callout)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .id(selection)
            HStack {
                Spacer()
                Button("settings.licenses.done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding()
        .frame(width: 520, height: 400)
        .task(id: selection) {
            content = nil
            let url = Bundle.main.url(forResource: selection.rawValue, withExtension: nil)
            let value = await Task.detached(priority: .utility) {
                url.flatMap { try? String(contentsOf: $0, encoding: .utf8) }
            }.value
            guard !Task.isCancelled else { return }
            content = value ?? String(localized: "settings.licenses.unavailable")
        }
    }
}
