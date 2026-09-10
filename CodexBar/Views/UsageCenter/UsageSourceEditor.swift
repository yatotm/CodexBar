import SwiftUI

struct UsageSourceEditor: View {
    @ObservedObject var viewModel: UsageCenterViewModel
    @State var source: UsageSource
    @State private var token = ""
    @State private var isSaving = false
    @State private var bridgeAction: Bool?
    @State private var bridgeMessage: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("统计来源").font(.title2.bold())
            Form {
                TextField("名称", text: $source.name)
                if source.id != "local" {
                    Picker("连接方式", selection: $source.transport) {
                        Text("SSH").tag(UsageTransport.ssh)
                        Text("HTTPS").tag(UsageTransport.https)
                    }
                }
                if source.transport == .ssh {
                    TextField("SSH 主机别名", text: $source.address, prompt: Text("例如 dev-a"))
                    Text("使用系统 SSH 配置和已有密钥。首次连接请先在终端完成主机身份校验。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if source.transport == .https {
                    TextField("服务地址", text: $source.address, prompt: Text("https://stats.example.com:8443"))
                    SecureField("统计服务令牌", text: $token, prompt: Text("留空保留原令牌"))
                    Text("填写自己统计端的令牌, 保存在 macOS 钥匙串。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Toggle("启用此来源", isOn: $source.isEnabled)
                Toggle("采集 Codex", isOn: $source.includesCodex)
                Toggle("采集 Claude Code", isOn: $source.includesClaude)
                if source.includesCodex {
                    LabeledContent("当前 Codex 凭据", value: viewModel.statuses[source.id]?.currentCodexAuthentication?.title ?? "尚未检测")
                    UsageDisclosure(title: "历史身份补充") {
                        Picker("缺失身份的补充标签", selection: $source.codexAuthentication) {
                            ForEach(UsageAuthentication.allCases) { Text($0.title).tag($0) }
                        }
                        Text("当前类型随刷新自动识别。此标签仅补充没有身份字段的旧日志, 不修改日志明确记录的登录方式。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if source.includesClaude {
                    Text("现有会话和额度缓存会自动读取, 无需点击接入。补充记录用于保存今后的权限请求、任务状态和官方状态栏提供的额度, 会调整 Claude 的 statusLine 与 Hook。")
                        .font(.caption).foregroundStyle(.secondary)
                    if source.transport != .https {
                        HStack {
                            Button("启用补充记录") { bridgeAction = true }
                            Button("移除接入") { bridgeAction = false }
                        }.disabled(isSaving || source.validationError != nil)
                    }
                }
                if source.transport != .https {
                    TextField("Codex 数据目录", text: $source.codexHome, prompt: Text("默认 CODEX_HOME 或 ~/.codex"))
                    TextField("Claude 数据目录", text: $source.claudeHome, prompt: Text("默认 CLAUDE_CONFIG_DIR 或 ~/.claude"))
                    TextField("远端统计缓存目录", text: Binding(
                        get: { source.collectorCacheDirectory ?? "" },
                        set: { source.collectorCacheDirectory = $0.isEmpty ? nil : $0 }
                    ), prompt: Text("可选, 如 /srv/codexbar/data"))
                    Text("填写缓存目录时读取定时采集器或统计服务的数据库, 不再次扫描日志。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.formStyle(.grouped)
            if let validation = source.validationError {
                Text(validation).font(.caption).foregroundStyle(.orange)
            }
            if let error = viewModel.error {
                Text(error).font(.caption).foregroundStyle(.orange)
            }
            if let bridgeMessage {
                Text(bridgeMessage).font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存") {
                    isSaving = true
                    Task {
                        if await viewModel.save(source, token: token) {
                            dismiss()
                        }
                        isSaving = false
                    }
                }.keyboardShortcut(.defaultAction)
                    .disabled(source.validationError != nil || isSaving)
            }
        }.padding(24).frame(width: 570, height: 660)
            .confirmationDialog("调整此机器的 Claude 配置?", isPresented: Binding(
                get: { bridgeAction != nil }, set: {
                    if !$0 {
                        bridgeAction = nil
                    }
                }
            )) {
                Button(bridgeAction == true ? "保留原状态栏并接入" : "恢复原状态栏并移除") {
                    guard let install = bridgeAction else { return }
                    bridgeAction = nil
                    isSaving = true
                    Task {
                        if await viewModel.configureClaude(source: source, install: install) {
                            bridgeMessage = install ? "已接入, 下一次 Claude 官方事件到达后开始记录" : "已移除接入"
                        }
                        isSaving = false
                    }
                }
            } message: {
                Text("接入会包装现有 statusLine 命令并追加只记录元数据的 Hook。原命令继续接收原始输入并显示原输出。移除时只恢复本程序管理的配置。")
            }
    }
}
