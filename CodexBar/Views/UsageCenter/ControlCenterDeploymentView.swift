import SwiftUI

struct ControlCenterDeploymentView: View {
    @ObservedObject var viewModel: UsageCenterViewModel
    @Binding var editingSource: UsageSource?
    @Binding var deletingSource: UsageSource?

    @State private var hubURLDraft = ""
    @State private var readTokenDraft = ""
    @State private var lanPortDraft = "18765"
    @State private var hasSavedToken = false
    @State private var isSavingHub = false
    @State private var showAddProbeSheet = false
    @State private var previewCommandTitle = ""
    @State private var previewCommandText: String?
    @State private var copiedBadgeID: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let error = viewModel.error {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                }
                topologySelectorCard
                if viewModel.topologyMode != .localOnly {
                    topologyConfigCard
                }
                nodesSectionCard
            }
            .padding(18)
        }
        .task { await syncDraftsFromModel() }
        .onChange(of: viewModel.topologyMode) { _, _ in
            Task { await syncDraftsFromModel() }
        }
        .sheet(isPresented: $showAddProbeSheet) {
            AddProbeNodeSheet(viewModel: viewModel) { title, cmd in
                previewCommandTitle = title
                previewCommandText = cmd
            }
        }
        .sheet(isPresented: Binding(
            get: { previewCommandText != nil },
            set: {
                if !$0 {
                    previewCommandText = nil
                }
            }
        )) {
            if let cmd = previewCommandText {
                ProbeCommandPreviewSheet(title: previewCommandTitle, command: cmd)
            }
        }
    }

    private func syncDraftsFromModel() async {
        hubURLDraft = viewModel.remoteHubURL
        lanPortDraft = String(viewModel.lanPort)
        hasSavedToken = await viewModel.hasSavedRemoteHubToken()
    }

    private var topologySelectorCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("部署与数据汇聚架构").font(.headline)
                Spacer()
                Text(viewModel.hubStatusText)
                    .font(.caption)
                    .foregroundStyle(statusColor)
            }
            Text("按机器网络拓扑选择汇聚方式; 外部节点均采用零 Hooks 单向签名推送探针, 更换中枢地址只需重新复制命令覆盖配置")
                .font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 12) {
                ForEach(ControlCenterTopologyMode.allCases) { mode in
                    topologyCardButton(mode)
                }
            }
        }
        .padding(16)
        .usageCenterCard()
    }

    private var statusColor: Color {
        guard let healthy = viewModel.hubHealthy else { return .secondary }
        return healthy ? .green : .orange
    }

    private func topologyCardButton(_ mode: ControlCenterTopologyMode) -> some View {
        let selected = viewModel.topologyMode == mode
        return Button {
            viewModel.topologyMode = mode
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: iconName(for: mode))
                        .foregroundStyle(selected ? Color.accentColor : .secondary)
                    Text(mode.title).font(.subheadline.weight(.semibold))
                    Spacer()
                    if selected {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentColor)
                    }
                }
                Text(mode.subtitle)
                    .font(.caption2).foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 84, alignment: .topLeading)
            .background(
                selected ? Color.accentColor.opacity(0.11) : Color.primary.opacity(0.03),
                in: RoundedRectangle(cornerRadius: 10)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(selected ? Color.accentColor.opacity(0.55) : Color.primary.opacity(0.08), lineWidth: 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func iconName(for mode: ControlCenterTopologyMode) -> String {
        switch mode {
        case .localOnly: "laptopcomputer"
        case .lanDirect: "wifi.router"
        case .remoteHub: "icloud.and.arrow.up"
        }
    }

    @ViewBuilder
    private var topologyConfigCard: some View {
        if viewModel.topologyMode == .lanDirect {
            lanConfigSection
        } else if viewModel.topologyMode == .remoteHub {
            remoteHubConfigSection
        }
    }

    private var lanConfigSection: some View {
        let addresses = HubCrypto.localIPv4Addresses()
        return VStack(alignment: .leading, spacing: 12) {
            Text("本机局域网 / 组网接收端").font(.subheadline.weight(.semibold))
            HStack(spacing: 10) {
                Text("监听端口").font(.caption).foregroundStyle(.secondary)
                TextField("18765", text: $lanPortDraft)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 96)
                Button("应用端口") {
                    Task { await saveHubConfig() }
                }
                .disabled(isSavingHub)
                Spacer()
                ForEach(addresses.prefix(3), id: \.self) { ip in
                    let endpoint = "http://\(ip):\(viewModel.lanPort)"
                    Button {
                        copyText(endpoint, badgeID: "ip:" + ip)
                    } label: {
                        Label(copiedBadgeID == "ip:" + ip ? "已复制" : endpoint, systemImage: "doc.on.doc")
                            .font(.caption.monospaced())
                    }
                    .buttonStyle(.bordered).controlSize(.small)
                }
            }
            Text("适用于无常驻公网服务器的场景; Mac 休眠或离线期间, 各外部机器探针会将用量缓存在本地 SQLite, 待 Mac 唤醒后自动补齐增量")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(16)
        .usageCenterCard()
    }

    private var remoteHubConfigSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("自建常驻中枢连接配置").font(.subheadline.weight(.semibold))
                Spacer()
                Button("生成新读取密钥") {
                    let generated = HubCrypto.randomToken(prefix: "cbr_")
                    readTokenDraft = generated
                    copyText(generated, badgeID: "gen-cbr")
                }
                .buttonStyle(.bordered).controlSize(.small)
                .help("生成 cbr_ 开头的只读拉取密钥并复制到剪贴板")
            }
            HStack(spacing: 10) {
                TextField("中枢 HTTPS 地址 (例如 https://hub.example.com:65120)", text: $hubURLDraft)
                    .textFieldStyle(.roundedBorder)
                SecureField(
                    hasSavedToken ? "读取密钥已存钥匙串, 留空保持不变" : "粘贴 HUB_READ_TOKEN (cbr_...)",
                    text: $readTokenDraft
                )
                .textFieldStyle(.roundedBorder)
                .frame(width: 260)
                Button("保存并连接") {
                    Task { await saveHubConfig() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isSavingHub || hubURLDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            Text("权限隔离: Mac 控制中心持有只读密钥 (cbr_), 外部探针各自持有独立单写签名密钥 (cbw_), 探针被盗也无法拉取其他机器数据")
                .font(.caption2).foregroundStyle(.secondary)
            HubBootstrapGuideView(hubURLDraft: hubURLDraft, readTokenDraft: readTokenDraft)
        }
        .padding(16)
        .usageCenterCard()
    }

    private func saveHubConfig() async {
        isSavingHub = true
        defer { isSavingHub = false }
        let parsedPort = Int(lanPortDraft.trimmingCharacters(in: .whitespacesAndNewlines)) ?? viewModel.lanPort
        let safePort = (1024 ... 65535).contains(parsedPort) ? parsedPort : 18765
        if await viewModel.saveHubSettings(
            mode: viewModel.topologyMode,
            hubURL: hubURLDraft,
            readToken: readTokenDraft,
            port: safePort
        ) {
            readTokenDraft = ""
            hasSavedToken = await viewModel.hasSavedRemoteHubToken()
        }
    }

    private var nodesSectionCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("监控节点与渠道管理").font(.subheadline.weight(.semibold))
                    Text("按机器独立开关 Codex, Claude 与 Gemini 渠道; 若某渠道在全部活跃节点均未开启, 托盘主弹窗将自动隐藏该标签页")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                if viewModel.topologyMode != .localOnly {
                    Menu {
                        Button("添加传统 SSH / HTTPS 来源") { editingSource = UsageSource() }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 24)
                    Button {
                        showAddProbeSheet = true
                    } label: {
                        Label("添加探针节点", systemImage: "plus")
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            VStack(spacing: 10) {
                ForEach(viewModel.effectiveSources) { source in
                    NodeConsoleRowView(
                        viewModel: viewModel,
                        source: source,
                        copiedBadgeID: copiedBadgeID,
                        onCopyCommand: { copyInstallCommand(for: source) },
                        onPreviewCommand: { previewInstallCommand(for: source, rotate: false) },
                        onRotateKey: { previewInstallCommand(for: source, rotate: true) },
                        onEditLegacy: { editingSource = source },
                        onDelete: { deletingSource = source }
                    )
                }
            }
        }
        .padding(16)
        .usageCenterCard()
    }

    private func copyInstallCommand(for source: UsageSource) {
        Task {
            if let cmd = await viewModel.installCommand(for: source) {
                copyText(cmd, badgeID: "cmd:" + source.id)
            } else {
                previewInstallCommand(for: source, rotate: true)
            }
        }
    }

    private func previewInstallCommand(for source: UsageSource, rotate: Bool) {
        Task {
            do {
                let cmd: String = if rotate {
                    try await viewModel.upsertProbeNode(
                        nodeID: source.id,
                        name: source.name,
                        includesCodex: source.includesCodex,
                        includesClaude: source.includesClaude,
                        includesGemini: source.includesGemini,
                        bridgeStatusLine: source.bridgeStatusLine,
                        rotateToken: true
                    )
                } else if let existing = await viewModel.installCommand(for: source) {
                    existing
                } else {
                    try await viewModel.upsertProbeNode(
                        nodeID: source.id,
                        name: source.name,
                        includesCodex: source.includesCodex,
                        includesClaude: source.includesClaude,
                        includesGemini: source.includesGemini,
                        bridgeStatusLine: source.bridgeStatusLine,
                        rotateToken: true
                    )
                }
                previewCommandTitle = rotate ? "\(source.name) · 新密钥部署命令" : "\(source.name) · 探针安装与覆盖配置命令"
                previewCommandText = cmd
            } catch {
                viewModel.error = error.localizedDescription
            }
        }
    }

    private func copyText(_ text: String, badgeID: String) {
        PasteboardWriter.copy(text)
        copiedBadgeID = badgeID
        Task {
            try? await Task.sleep(for: .seconds(2))
            if copiedBadgeID == badgeID {
                copiedBadgeID = nil
            }
        }
    }
}

private struct NodeConsoleRowView: View {
    @ObservedObject var viewModel: UsageCenterViewModel
    let source: UsageSource
    let copiedBadgeID: String?
    let onCopyCommand: () -> Void
    let onPreviewCommand: () -> Void
    let onRotateKey: () -> Void
    let onEditLegacy: () -> Void
    let onDelete: () -> Void

    private var status: UsageSourceStatus? {
        viewModel.statuses[source.id]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            topRow
            channelRow
            if let error = status?.error {
                Text(error).font(.caption2).foregroundStyle(.orange)
            }
            ForEach(status?.warnings ?? [], id: \.self) { warning in
                Text(warning).font(.caption2).foregroundStyle(.orange)
            }
        }
        .padding(12)
        .background(Color.primary.opacity(0.028), in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.8)
        }
    }

    private var topRow: some View {
        HStack(spacing: 10) {
            Image(systemName: symbolName)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(source.isEnabled ? Color.accentColor : .secondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(source.name).font(.subheadline.weight(.semibold))
                    Text(source.id).font(.caption2.monospaced()).foregroundStyle(.secondary)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.primary.opacity(0.06), in: Capsule())
                    onlineBadge
                }
                Text(metaSummary).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            actionControls
        }
    }

    private var symbolName: String {
        switch source.transport {
        case .local: "laptopcomputer"
        case .probe: "antenna.radiowaves.left.and.right"
        case .ssh, .https: "server.rack"
        }
    }

    @ViewBuilder
    private var onlineBadge: some View {
        if !source.isEnabled {
            badgePill("已停用", color: .secondary)
        } else if source.transport == .local {
            badgePill("本机直读", color: .green)
        } else if source.transport == .probe {
            badgePill(source.isOnline ? "探针在线" : "离线待连", color: source.isOnline ? .green : .orange)
        } else {
            badgePill(source.transport.rawValue.uppercased(), color: .blue)
        }
    }

    private func badgePill(_ label: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(label).font(.caption2.weight(.medium)).foregroundStyle(color)
        }
        .padding(.horizontal, 7).padding(.vertical, 2)
        .background(color.opacity(0.12), in: Capsule())
    }

    private var metaSummary: String {
        var parts: [String] = []
        if !source.platformName.isEmpty {
            parts.append(source.platformName)
        }
        if !source.probeVersion.isEmpty {
            parts.append("v" + source.probeVersion)
        }
        if !source.detectedProviders.isEmpty {
            parts.append("检测到: " + source.detectedProviders.joined(separator: "/"))
        }
        if let seen = source.lastSeenAt {
            parts.append("心跳 " + Date(timeIntervalSince1970: seen).formatted(date: .abbreviated, time: .shortened))
        } else if let last = status?.lastSuccess {
            parts.append("更新于 " + last.formatted(date: .abbreviated, time: .shortened))
        }
        return parts.isEmpty ? (source.transport == .local ? "本机原生目录与状态栏无感桥接" : "等待首次探针上报") : parts.joined(separator: " · ")
    }

    private var actionControls: some View {
        HStack(spacing: 8) {
            if source.transport == .probe {
                Button(action: onCopyCommand) {
                    Label(
                        copiedBadgeID == "cmd:" + source.id ? "已复制命令" : "复制安装命令",
                        systemImage: copiedBadgeID == "cmd:" + source.id ? "checkmark" : "terminal"
                    )
                }
                .buttonStyle(.bordered).controlSize(.small)
                Menu {
                    Button("查看完整部署命令", action: onPreviewCommand)
                    Button("轮换节点写入密钥", action: onRotateKey)
                    Divider()
                    Button("移除节点", role: .destructive, action: onDelete)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 24)
            } else {
                Button(action: onEditLegacy) {
                    Label("目录设置", systemImage: "slider.horizontal.3")
                }
                .buttonStyle(.bordered).controlSize(.small)
                if source.id != "local" {
                    Button(role: .destructive, action: onDelete) {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless).controlSize(.small)
                }
            }
            Toggle("", isOn: Binding(
                get: { source.isEnabled },
                set: { enabled in Task { await viewModel.setSourceEnabled(enabled, for: source) } }
            ))
            .toggleStyle(.switch).controlSize(.small).labelsHidden()
            .help("启用或暂停此节点")
        }
    }

    private var channelRow: some View {
        HStack(spacing: 14) {
            Text("监控渠道").font(.caption).foregroundStyle(.secondary)
            channelToggle("Codex", scope: .codex, isOn: source.includesCodex)
            channelToggle("Claude", scope: .claude, isOn: source.includesClaude)
            channelToggle("Gemini (agy)", scope: .gemini, isOn: source.includesGemini)
            Spacer()
            if source.transport == .local || source.transport == .probe {
                Toggle("状态栏无感桥接", isOn: Binding(
                    get: { source.bridgeStatusLine },
                    set: { enabled in Task { await viewModel.setBridgeStatusLine(enabled, for: source) } }
                ))
                .toggleStyle(.checkbox).controlSize(.small).font(.caption)
                .help("自动包装 Claude 与 agy 的 statusLine 以采集官方 5h/7d 额度与实时状态, 不注入生命周期 Hooks")
            }
        }
    }

    private func channelToggle(_ label: String, scope: UsageMenuScope, isOn: Bool) -> some View {
        Toggle(label, isOn: Binding(
            get: { isOn },
            set: { next in Task { await viewModel.setChannel(scope, enabled: next, for: source) } }
        ))
        .toggleStyle(.checkbox).controlSize(.small).font(.caption)
        .disabled(!source.isEnabled)
    }
}

private struct HubBootstrapGuideView: View {
    let hubURLDraft: String
    let readTokenDraft: String
    @State private var copied = false

    private var sampleToken: String {
        let trimmed = readTokenDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "<你的_HUB_READ_TOKEN>" : trimmed
    }

    private var tokenHashNote: String {
        let trimmed = readTokenDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return "提示: 先点击上方「生成新读取密钥」, 下方命令会自动填入对应 SHA-256 哈希"
        }
        return "已根据上方输入的读取密钥自动计算 SHA-256 校验哈希, 服务端仅保存哈希值"
    }

    private var serverCommand: String {
        let trimmed = readTokenDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let hashExpr = trimmed.isEmpty
            ? "$(printf 'codexbar-hub-read-v1:%s' '\(sampleToken)' | sha256sum | awk '{print $1}')"
            : HubCrypto.hashReadToken(rawReadToken: trimmed)
        return """
        sudo mkdir -p /opt/codexbar-hub /var/lib/codexbar-hub
        # 将仓库 CodexBar/Resources 下的 CodexBarHub.py, CodexBarProbe.py, UsageCollector.py 上传至 /opt/codexbar-hub/
        python3 /opt/codexbar-hub/CodexBarHub.py serve \\
            --state-dir /var/lib/codexbar-hub \\
            --listen 127.0.0.1 --port 18765 \\
            --read-token-hash '\(hashExpr)'
        """
    }

    var body: some View {
        UsageDisclosure(title: "常驻中枢服务端部署说明 (无需安装 Codex / Claude / agy)") {
            VStack(alignment: .leading, spacing: 8) {
                Text("中枢机仅需 Python 3.9+ 与 Nginx TLS 反向代理 (关闭 /v1/events 的 proxy_buffering 以支持长轮询实时推送)")
                    .font(.caption2).foregroundStyle(.secondary)
                Text(tokenHashNote).font(.caption2).foregroundStyle(.secondary)
                Text(serverCommand)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                Button(copied ? "已复制启动命令" : "复制启动命令") {
                    PasteboardWriter.copy(serverCommand)
                    copied = true
                }
                .buttonStyle(.bordered).controlSize(.small)
            }
        }
        .font(.caption)
    }
}

private struct AddProbeNodeSheet: View {
    @ObservedObject var viewModel: UsageCenterViewModel
    let onCreated: (String, String) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var nodeID = ""
    @State private var includesCodex = true
    @State private var includesClaude = true
    @State private var includesGemini = true
    @State private var bridgeStatusLine = true
    @State private var isSubmitting = false
    @State private var localError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("添加外部探针节点").font(.title3.bold())
            Form {
                TextField("显示名称", text: $name, prompt: Text("例如 sk_203 或 局域网主机"))
                    .onChange(of: name) { _, newValue in
                        if nodeID.isEmpty || nodeID == sanitizedID(from: String(newValue.dropLast())) {
                            nodeID = sanitizedID(from: newValue)
                        }
                    }
                TextField("节点唯一标识", text: $nodeID, prompt: Text("仅限字母, 数字, - 和 _, 例如 sk_203"))
                Section("初始监控渠道 (后续可在控制台随时远程切换)") {
                    Toggle("采集 Codex", isOn: $includesCodex)
                    Toggle("采集 Claude Code", isOn: $includesClaude)
                    Toggle("采集 Gemini (agy)", isOn: $includesGemini)
                    Toggle("启用状态栏无感桥接 (采集 5h/7d 额度与实时状态, 零 Hooks)", isOn: $bridgeStatusLine)
                }
            }
            .formStyle(.grouped)
            if let localError {
                Text(localError).font(.caption).foregroundStyle(.orange)
            }
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("注册并生成安装命令") {
                    submit()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(isSubmitting || name.trimmingCharacters(in: .whitespaces).isEmpty || nodeID.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(22)
        .frame(width: 500, height: 420)
    }

    private func sanitizedID(from raw: String) -> String {
        let allowed = raw.lowercased().map { ch -> Character in
            if ch.isASCII, ch.isLetter || ch.isNumber || ch == "-" || ch == "_" {
                return ch
            }
            return "-"
        }
        let collapsed = String(allowed).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return String(collapsed.prefix(32))
    }

    private func submit() {
        isSubmitting = true
        localError = nil
        Task {
            defer { isSubmitting = false }
            do {
                let cmd = try await viewModel.upsertProbeNode(
                    nodeID: nodeID,
                    name: name,
                    includesCodex: includesCodex,
                    includesClaude: includesClaude,
                    includesGemini: includesGemini,
                    bridgeStatusLine: bridgeStatusLine,
                    rotateToken: true
                )
                let displayName = name.trimmingCharacters(in: .whitespacesAndNewlines)
                dismiss()
                onCreated("\(displayName) · 探针一键部署命令", cmd)
            } catch {
                localError = error.localizedDescription
            }
        }
    }
}

private struct ProbeCommandPreviewSheet: View {
    let title: String
    let command: String
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.title3.bold())
            Text("在目标机器终端执行以下单行命令即可完成探针客户端下载, 鉴权配置写入与后台自启注册; 更换中枢地址时直接重新执行即可覆盖配置, 无需配置 SSH 入站")
                .font(.caption).foregroundStyle(.secondary)
            Text(command)
                .font(.system(size: 11.5, design: .monospaced))
                .textSelection(.enabled)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
            Text("安全说明: CODEXBAR_TOKEN 通过环境变量传给安装脚本并写入 0600 权限配置文件, 不会出现在 URL 查询参数或后台常驻进程命令行中")
                .font(.caption2).foregroundStyle(.tertiary)
            HStack {
                Button {
                    PasteboardWriter.copy(command)
                    copied = true
                } label: {
                    Label(copied ? "已复制到剪贴板" : "一键复制安装命令", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(.borderedProminent)
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 580)
    }
}
