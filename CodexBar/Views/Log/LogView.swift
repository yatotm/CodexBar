import AppKit
import SwiftUI

/// app-server 交互日志窗口根视图
struct LogView: View {
    @ObservedObject var store: RequestLogStore
    @State private var preview = LogPreviewPresentation()
    @State private var scrollPosition = ScrollPosition(idType: UUID.self, edge: .top)

    var body: some View {
        // 每轮渲染只取一次发布快照复用
        let entries = store.entries
        VStack(spacing: 0) {
            header(entries: entries)
            Divider()

            if entries.isEmpty {
                emptyState
            } else {
                logList(entries: entries)
            }
        }
        .frame(minWidth: 640, minHeight: 480)
        .task(id: preview.request?.id) {
            if let request = preview.request {
                await preview.prepare(request)
            }
        }
        .sheet(item: $preview.item) { item in
            FullLogTextView(item: item)
                .onDisappear { preview.dismiss(item) }
        }
        .onDisappear { preview.cancel() }
    }

    private func header(entries: [RequestLogEntry]) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "doc.text.magnifyingglass")
                .foregroundStyle(.tint)

            Text("log.window.app-server-title")
                .font(.headline)

            Text(verbatim: "\(entries.count)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(Capsule().fill(.quaternary))

            Spacer()

            Button {
                store.clear()
            } label: {
                Label("common.action.clear", systemImage: "trash")
            }
            .controlSize(.small)
            .disabled(entries.isEmpty)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "tray")
                .font(.largeTitle)
                .foregroundStyle(.tertiary)

            Text("log.empty.no-entries")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func logList(entries: [RequestLogEntry]) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(entries) { entry in
                    VStack(spacing: 0) {
                        LogRow(entry: entry, preview: preview)
                        Divider()
                    }
                }
            }
            .scrollTargetLayout()
        }
        .scrollPosition($scrollPosition, anchor: .top)
        .onScrollPhaseChange { _, phase, context in
            // 浏览时按日志身份保持位置, 回到顶部后才重新跟随新日志
            if phase == .idle, context.geometry.contentOffset.y + context.geometry.contentInsets.top <= 1 {
                scrollPosition.scrollTo(edge: .top)
            }
        }
        .onDisappear { scrollPosition = ScrollPosition(idType: UUID.self, edge: .top) }
        .background(Color(nsColor: .textBackgroundColor))
    }
}

// MARK: - 单条日志行

/// 单条日志行, 摘要行可展开查看请求和响应预览
private struct LogRow: View {
    let entry: RequestLogEntry
    @State private var isExpanded = false
    let preview: LogPreviewPresentation
    @State private var inlinePreview: LogInlinePreview?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.snappy(duration: 0.18)) {
                    isExpanded.toggle()
                }
            } label: {
                summary
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    if let request = entry.request {
                        payloadBlock(
                            caption: "log.payload.request",
                            time: entry.requestedAt,
                            text: request,
                            inline: currentInlinePreview?.request,
                            color: .primary
                        )
                    }

                    if let detail = entry.detail {
                        payloadBlock(
                            caption: detailCaption,
                            time: entry.respondedAt,
                            text: detail,
                            inline: currentInlinePreview?.detail,
                            color: entry.kind == .failure ? .red : .primary
                        )
                    } else if entry.kind == .pending {
                        Text("log.status.waiting-response")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.top, 6)
                .padding(.leading, 20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .task(id: inlineInput) {
            let input = inlineInput
            guard inlinePreview?.input != input else { return }
            do {
                let result = try await LogPreviewPreparer.shared.inlinePreview(for: input)
                try Task.checkCancellation()
                inlinePreview = result
            } catch is CancellationError {
                // 行离开列表或正文更新后, 由下一次任务生成摘要
            } catch {
                assertionFailure("Unexpected inline preview error: \(error)")
            }
        }
        .onDisappear { preview.cancel(for: entry.id) }
    }

    private var inlineInput: LogInlinePreviewInput {
        LogInlinePreviewInput(request: entry.request, detail: entry.detail, needsSummary: entry.method == nil)
    }

    private var currentInlinePreview: LogInlinePreview? {
        inlinePreview?.input == inlineInput ? inlinePreview : nil
    }

    private var summary: some View {
        HStack(spacing: 8) {
            Image(systemName: "chevron.right")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                .frame(width: 12)

            Text(Self.timeFormatter.string(from: entry.requestedAt))
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)

            Text(entry.kind.label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(entry.kind.tint)
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(entry.kind.tint.opacity(0.14))
                )

            if let method = entry.method {
                Text(method)
                    .font(.caption.weight(.medium).monospaced())
                    .foregroundStyle(.primary)
            } else if entry.detail != nil {
                // 无方法名的记录 (信息/进程级错误) 直接预览正文
                // 避免标签后留空
                Text(verbatim: currentInlinePreview?.summary ?? "")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }

    private func payloadBlock(
        caption: LocalizedStringResource,
        time: Date?,
        text: String,
        inline: LogInlinePreview.Payload?,
        color: Color
    ) -> some View {
        let caption = String(localized: caption)

        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(caption)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)

                if let time {
                    Text(Self.timeFormatter.string(from: time))
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                }

                if inline?.hasText == true {
                    LogHeaderActionButton(
                        title: "common.action.preview",
                        systemImage: "doc.text.magnifyingglass",
                        help: String(localized: "log.action.preview-full", defaultValue: "\(caption)")
                    ) {
                        preview.show(entryID: entry.id, title: caption, text: text)
                    }

                    LogHeaderActionButton(
                        title: "common.action.copy",
                        systemImage: "doc.on.doc",
                        help: String(localized: "log.action.copy-full", defaultValue: "\(caption)")
                    ) {
                        PasteboardWriter.copy(text)
                    }
                }
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .font(.caption)

            Text(verbatim: inline?.text ?? "")
                .font(.caption.monospaced())
                .foregroundStyle(color)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var detailCaption: LocalizedStringResource {
        switch entry.kind {
        case .response, .emptyResponse:
            "log.payload.response"
        case .failure:
            "log.label.error"
        default:
            "log.payload.details"
        }
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()
}

// MARK: - 全文查看

/// 复制/预览按钮的统一样式入口
private struct LogHeaderActionButton: View {
    let title: LocalizedStringResource
    let systemImage: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
        }
        .help(help)
    }
}

/// 完整请求/响应预览弹窗
private struct FullLogTextView: View {
    let item: LogPreviewPresentation.Item
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text(item.request.title)
                    .font(.headline)

                Text(verbatim: "\(item.document.characterCount)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)

                if let language = item.document.language {
                    Text(language)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(.quaternary)
                        )
                }

                Spacer()

                Button {
                    PasteboardWriter.copy(item.request.text)
                } label: {
                    Label("common.action.copy", systemImage: "doc.on.doc")
                }
                .controlSize(.small)

                Button {
                    dismiss()
                } label: {
                    Label("common.action.close", systemImage: "xmark")
                }
                .controlSize(.small)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider()

            LogCodePreviewView(document: item.document)
                .id(item.id)
                .frame(minWidth: 860, minHeight: 600)
        }
    }
}

private extension RequestLogEntry.Kind {
    var label: LocalizedStringResource {
        switch self {
        case .pending:
            "log.status.in-progress"
        case .response:
            "common.status.completed"
        case .failure:
            "log.label.error"
        case .emptyResponse:
            "log.payload.request"
        }
    }

    var tint: Color {
        switch self {
        case .pending:
            .orange
        case .response:
            .green
        case .failure:
            .red
        case .emptyResponse:
            .blue
        }
    }
}
