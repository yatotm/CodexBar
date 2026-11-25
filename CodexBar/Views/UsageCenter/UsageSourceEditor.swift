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
            Text(source.id == "local" ? "本机目录与高级设置" : "传统统计来源设置").font(.title2.bold())
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
                    Text("使用系统 SSH 配置和已有密钥; 外部多机推荐使用「节点与部署」中的单向探针模式")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if source.transport == .https {
                    TextField("服务地址", text: $source.address, prompt: Text("https://stats.example.com:8443"))
                    SecureField("统计服务令牌", text: $token, prompt: Text("留空保留原令牌"))
                    Text("填写自己统计端的令牌, 保存在 macOS 钥匙串")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Toggle("启用此节点", isOn: $source.isEnabled)
                Toggle("采集 Codex", isOn: $source.includesCodex)
                Toggle("采集 Claude Code", isOn: $source.includesClaude)
                Toggle("采集 Gemini (agy)", isOn: $source.includesGemini)
                if source.transport == .local {
                    Toggle("启用状态栏无感桥接 (Claude / agy 额度与实时状态)", isOn: $source.bridgeStatusLine)
                    Text("自动包装本机 Claude 与 agy 的 statusLine, 保留原有自定义状态栏显示, 不注入生命周期 Hooks")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if source.includesCodex {
                    LabeledContent("当前 Codex 凭据", value: viewModel.statuses[source.id]?.currentCodexAuthentication?.title ?? "尚未检测")
                    UsageDisclosure(title: "历史身份补充") {
                        Picker("缺失身份的补充标签", selection: $source.codexAuthentication) {
                            ForEach(UsageAuthentication.allCases) { Text($0.title).tag($0) }
                        }
                        Text("当前类型随刷新自动识别; 此标签仅补充没有身份字段的旧日志, 不修改日志明确记录的登录方式")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if source.includesClaude, source.transport == .ssh {
                    HStack {
                        Button("启用状态栏桥接") { bridgeAction = true }
                        Button("移除状态栏桥接") { bridgeAction = false }
                    }.disabled(isSaving || source.validationError != nil)
                }
                if source.transport != .https {
                    TextField("Codex 数据目录", text: $source.codexHome, prompt: Text("默认 CODEX_HOME 或 ~/.codex"))
                    TextField("Claude 数据目录", text: $source.claudeHome, prompt: Text("默认 CLAUDE_CONFIG_DIR 或 ~/.claude"))
                    TextField("Gemini 数据目录", text: $source.geminiHome, prompt: Text("默认 ~/.gemini/antigravity-cli"))
                    if source.transport == .ssh {
                        TextField("远端统计缓存目录", text: Binding(
                            get: { source.collectorCacheDirectory ?? "" },
                            set: { source.collectorCacheDirectory = $0.isEmpty ? nil : $0 }
                        ), prompt: Text("可选, 如 /srv/codexbar/data"))
                    }
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
        }.padding(24).frame(width: 570, height: 680)
            .confirmationDialog("调整此机器的 Claude 状态栏配置?", isPresented: Binding(
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
                            bridgeMessage = install ? "已接入状态栏无感桥接, 下一次刷新开始记录" : "已移除接入"
                        }
                        isSaving = false
                    }
                }
            } message: {
                Text("接入仅包装现有 statusLine 命令, 不安装生命周期 Hooks; 原命令继续接收原始输入并显示原输出")
            }
    }
}
