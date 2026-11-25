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
        VStack(alignment: .leading, spacing: 16) {
            ControlCenterSectionHeader(
                title: source.id == "local" ? "本机目录与高级设置" : "传统统计来源设置",
                subtitle: source.id == "local" ? "自定义本机工具目录与状态栏桥接行为" : "外部多机推荐使用「节点与部署」中的零 Hooks 单向探针模式",
                symbol: source.id == "local" ? "laptopcomputer" : "server.rack",
                tint: .accentColor
            )
            Form {
                TextField("显示名称", text: $source.name)
                if source.id != "local" {
                    Picker("连接方式", selection: $source.transport) {
                        Text("SSH").tag(UsageTransport.ssh)
                        Text("HTTPS").tag(UsageTransport.https)
                    }
                }
                if source.transport == .ssh {
                    TextField("SSH 主机别名", text: $source.address, prompt: Text("例如 dev-a"))
                    Text("复用系统 ~/.ssh/config 配置与已有密钥")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if source.transport == .https {
                    TextField("服务地址", text: $source.address, prompt: Text("https://stats.example.com:8443"))
                    SecureField("统计服务令牌", text: $token, prompt: Text("留空保留原令牌"))
                }
                Section("启用状态与采集渠道") {
                    Toggle("启用此节点", isOn: $source.isEnabled)
                    Toggle("采集 Codex", isOn: $source.includesCodex)
                    Toggle("采集 Claude Code", isOn: $source.includesClaude)
                    Toggle("采集 Gemini (agy)", isOn: $source.includesGemini)
                    if source.transport == .local {
                        Toggle("启用状态栏无感桥接 (Claude / agy 额度与实时状态)", isOn: $source.bridgeStatusLine)
                    }
                }
                if source.includesCodex {
                    Section("Codex 身份识别") {
                        LabeledContent("当前 Codex 凭据", value: viewModel.statuses[source.id]?.currentCodexAuthentication?.title ?? "尚未检测")
                        Picker("缺失身份的旧日志补充标签", selection: $source.codexAuthentication) {
                            ForEach(UsageAuthentication.allCases) { Text($0.title).tag($0) }
                        }
                    }
                }
                if source.includesClaude, source.transport == .ssh {
                    Section("远端状态栏桥接") {
                        HStack {
                            Button("启用状态栏桥接") { bridgeAction = true }
                            Button("移除状态栏桥接") { bridgeAction = false }
                        }
                        .disabled(isSaving || source.validationError != nil)
                    }
                }
                if source.transport != .https {
                    Section("自定义目录路径 (留空采用默认路径)") {
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
                }
            }
            .formStyle(.grouped)
            statusMessages
            footerButtons
        }
        .padding(22)
        .frame(width: 580, height: 660)
        .confirmationDialog("调整此机器的 Claude 状态栏配置?", isPresented: Binding(
            get: { bridgeAction != nil },
            set: {
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

    @ViewBuilder
    private var statusMessages: some View {
        if let validation = source.validationError {
            Text(validation).font(.caption).foregroundStyle(.orange)
        }
        if let error = viewModel.error {
            Text(error).font(.caption).foregroundStyle(.orange)
        }
        if let bridgeMessage {
            Text(bridgeMessage).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var footerButtons: some View {
        HStack {
            Spacer()
            Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
            Button("保存更改") {
                isSaving = true
                Task {
                    if await viewModel.save(source, token: token) {
                        dismiss()
                    }
                    isSaving = false
                }
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .disabled(source.validationError != nil || isSaving)
        }
    }
}
