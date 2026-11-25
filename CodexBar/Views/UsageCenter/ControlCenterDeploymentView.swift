import SwiftUI

struct ControlCenterDeploymentView: View {
    @ObservedObject var viewModel: UsageCenterViewModel
    @Binding var editingSource: UsageSource?
    @Binding var deletingSource: UsageSource?
    @Binding var showAddProbeSheet: Bool

    @State private var hubURLDraft = ""
    @State private var readTokenDraft = ""
    @State private var lanPortDraft = "18765"
    @State private var hasSavedToken = false
    @State private var isSavingHub = false
    @State private var previewCommandTitle = ""
    @State private var previewCommandText: String?
    @State private var copiedBadgeID: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let error = viewModel.error {
                    errorBanner(error)
                }
                topologySelectorCard
                if viewModel.topologyMode != .localOnly {
                    topologyConfigCard
                }
                nodesSectionCard
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 18)
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

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(message).font(.system(size: 12)).foregroundStyle(.primary)
            Spacer()
        }
        .padding(12)
        .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.orange.opacity(0.28), lineWidth: 0.8)
        }
    }

    private func syncDraftsFromModel() async {
        hubURLDraft = viewModel.remoteHubURL
        lanPortDraft = String(viewModel.lanPort)
        hasSavedToken = await viewModel.hasSavedRemoteHubToken()
    }

    private var topologySelectorCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            ControlCenterSectionHeader(
                title: "数据汇聚拓扑",
                subtitle: "外部机器均通过零 Hooks 单向签名探针上报; 切换架构只需重新执行安装命令覆盖配置",
                symbol: "point.3.connected.trianglepath.dotted",
                tint: .indigo
            ) {
                ControlCenterStatusBadge(title: viewModel.hubStatusText, color: statusColor)
            }
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
        if viewModel.topologyMode == .localOnly {
            return ControlCenterPalette.codex
        }
        guard let healthy = viewModel.hubHealthy else { return .secondary }
        return healthy ? .green : .orange
    }

    private func topologyCardButton(_ mode: ControlCenterTopologyMode) -> some View {
        let selected = viewModel.topologyMode == mode
        return Button {
            withAnimation(.easeOut(duration: 0.15)) {
                viewModel.topologyMode = mode
            }
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: iconName(for: mode))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(selected ? .white : .secondary)
                        .frame(width: 28, height: 28)
                        .background(
                            selected ? Color.accentColor : Color.primary.opacity(0.06),
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                        )
                    Text(mode.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary)
                    Spacer()
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 14))
                        .foregroundStyle(selected ? Color.accentColor : Color.secondary.opacity(0.35))
                }
                Text(mode.subtitle)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 96, alignment: .topLeading)
            .background(
                selected ? Color.accentColor.opacity(0.08) : Color.primary.opacity(0.025),
                in: RoundedRectangle(cornerRadius: 11, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(selected ? Color.accentColor.opacity(0.65) : Color.primary.opacity(0.07), lineWidth: selected ? 1.2 : 0.8)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func iconName(for mode: ControlCenterTopologyMode) -> String {
        switch mode {
        case .localOnly: "laptopcomputer"
        case .lanDirect: "wifi.router.fill"
        case .remoteHub: "server.rack"
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
        return VStack(alignment: .leading, spacing: 14) {
            ControlCenterSectionHeader(
                title: "本机局域网 / 组网接收服务",
                subtitle: "Mac 离线或休眠期间探针自动缓存至本地 SQLite, 唤醒后无损补齐增量",
                symbol: "wifi.router.fill",
                tint: .teal
            )
            HStack(spacing: 10) {
                Text("监听端口")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                TextField("18765", text: $lanPortDraft)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 96)
                Button("保存端口") {
                    Task { await saveHubConfig() }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(isSavingHub)
                Spacer()
                ForEach(addresses.prefix(3), id: \.self) { ip in
                    let endpoint = "http://\(ip):\(viewModel.lanPort)"
                    Button {
                        copyText(endpoint, badgeID: "ip:" + ip)
                    } label: {
                        Label(copiedBadgeID == "ip:" + ip ? "已复制" : endpoint, systemImage: copiedBadgeID == "ip:" + ip ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 11.5, design: .monospaced))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        }
        .padding(16)
        .usageCenterCard()
    }

    private var remoteHubConfigSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            ControlCenterSectionHeader(
                title: "自建常驻中枢连接",
                subtitle: "控制中心持有只读密钥 (cbr_), 外部探针各自持有独立单写密钥 (cbw_), 权限严格单向隔离",
                symbol: "lock.shield.fill",
                tint: ControlCenterPalette.codex
            ) {
                Button {
                    let generated = HubCrypto.randomToken(prefix: "cbr_")
                    readTokenDraft = generated
                    copyText(generated, badgeID: "gen-cbr")
                } label: {
                    Label(copiedBadgeID == "gen-cbr" ? "已复制新密钥" : "生成新读取密钥", systemImage: "key.fill")
                        .font(.system(size: 11.5, weight: .medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            HStack(spacing: 10) {
                TextField("中枢 HTTPS 地址 (例如 https://hub.example.com:65120)", text: $hubURLDraft)
                    .textFieldStyle(.roundedBorder)
                SecureField(
                    hasSavedToken ? "读取密钥已安全保存, 留空保持不变" : "粘贴 HUB_READ_TOKEN (cbr_...)",
                    text: $readTokenDraft
                )
                .textFieldStyle(.roundedBorder)
                .frame(width: 260)
                Button("保存并重连") {
                    Task { await saveHubConfig() }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .disabled(isSavingHub || hubURLDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
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
        VStack(alignment: .leading, spacing: 14) {
            ControlCenterSectionHeader(
                title: "监控节点与渠道控制台",
                subtitle: "点击胶囊随时开关对应机器的监控渠道; 若某渠道在全部活跃机器上均关闭, 托盘弹窗将自动隐藏该标签页",
                symbol: "cpu.fill",
                tint: .green
            ) {
                if viewModel.topologyMode != .localOnly {
                    Menu {
                        Button("添加探针节点…") { showAddProbeSheet = true }
                        Divider()
                        Button("添加传统 SSH / HTTPS 来源…") { editingSource = UsageSource() }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.secondary)
                            .frame(width: 28, height: 28)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .frame(width: 28)
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

// MARK: - 节点控制卡片与渠道胶囊开关

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
        VStack(alignment: .leading, spacing: 12) {
            topRow
            Divider().opacity(0.45)
            channelPillBar
            if let error = status?.error {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.orange)
            }
            ForEach(status?.warnings ?? [], id: \.self) { warning in
                Text(warning).font(.system(size: 11.5)).foregroundStyle(.orange)
            }
        }
        .padding(14)
        .usageCenterInset(cornerRadius: 11)
    }

    private var topRow: some View {
        HStack(spacing: 12) {
            Image(systemName: symbolName)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(source.isEnabled ? Color.accentColor : .secondary)
                .frame(width: 32, height: 32)
                .background(
                    (source.isEnabled ? Color.accentColor : Color.secondary).opacity(0.12),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(source.name)
                        .font(.system(size: 13.5, weight: .semibold))
                    Text(source.id)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Color.primary.opacity(0.055), in: Capsule())
                    onlineBadge
                }
                Text(metaSummary)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
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
            ControlCenterStatusBadge(title: "已停用", color: .secondary)
        } else if source.transport == .local {
            ControlCenterStatusBadge(title: "本机直读", color: .green)
        } else if source.transport == .probe {
            ControlCenterStatusBadge(
                title: source.isOnline ? "探针在线" : "离线待连",
                color: source.isOnline ? .green : .orange
            )
        } else {
            ControlCenterStatusBadge(title: source.transport.rawValue.uppercased(), color: ControlCenterPalette.codex)
        }
    }

    private var metaSummary: String {
        var parts: [String] = []
        if !source.platformName.isEmpty {
            parts.append(source.platformName)
        }
        if !source.probeVersion.isEmpty {
            parts.append("探针 v" + source.probeVersion)
        }
        if !source.detectedProviders.isEmpty {
            parts.append("已安装 " + source.detectedProviders.joined(separator: " / "))
        }
        if let seen = source.lastSeenAt {
            parts.append("最近心跳 " + Date(timeIntervalSince1970: seen).formatted(date: .abbreviated, time: .shortened))
        } else if let last = status?.lastSuccess {
            parts.append("同步于 " + last.formatted(date: .abbreviated, time: .shortened))
        }
        return parts.isEmpty ? (source.transport == .local ? "本机原生目录与状态栏无感桥接" : "等待首次探针上报") : parts.joined(separator: " · ")
    }

    private var actionControls: some View {
        HStack(spacing: 8) {
            if source.transport == .probe {
                Button(action: onCopyCommand) {
                    Label(
                        copiedBadgeID == "cmd:" + source.id ? "已复制" : "安装命令",
                        systemImage: copiedBadgeID == "cmd:" + source.id ? "checkmark" : "terminal"
                    )
                    .font(.system(size: 11.5, weight: .medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                Menu {
                    Button("查看完整部署命令…", action: onPreviewCommand)
                    Button("轮换节点写入密钥…", action: onRotateKey)
                    Divider()
                    Button("移除节点", role: .destructive, action: onDelete)
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 13.5))
                        .foregroundStyle(.secondary)
                        .frame(width: 26, height: 26)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 26)
            } else {
                Button(action: onEditLegacy) {
                    Label("目录设置", systemImage: "slider.horizontal.3")
                        .font(.system(size: 11.5, weight: .medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                if source.id != "local" {
                    Button(role: .destructive, action: onDelete) {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                }
            }
            Toggle("", isOn: Binding(
                get: { source.isEnabled },
                set: { enabled in Task { await viewModel.setSourceEnabled(enabled, for: source) } }
            ))
            .toggleStyle(.switch)
            .controlSize(.small)
            .labelsHidden()
            .help("启用或暂停此节点")
        }
    }

    private var channelPillBar: some View {
        HStack(spacing: 8) {
            Text("监控渠道")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.trailing, 2)
            ChannelToggleChip(
                label: "Codex",
                tint: ControlCenterPalette.codex,
                isOn: source.includesCodex,
                isDisabled: !source.isEnabled
            ) {
                Task { await viewModel.setChannel(.codex, enabled: !source.includesCodex, for: source) }
            }
            ChannelToggleChip(
                label: "Claude",
                tint: ControlCenterPalette.claude,
                isOn: source.includesClaude,
                isDisabled: !source.isEnabled
            ) {
                Task { await viewModel.setChannel(.claude, enabled: !source.includesClaude, for: source) }
            }
            ChannelToggleChip(
                label: "Gemini (agy)",
                tint: ControlCenterPalette.gemini,
                isOn: source.includesGemini,
                isDisabled: !source.isEnabled
            ) {
                Task { await viewModel.setChannel(.gemini, enabled: !source.includesGemini, for: source) }
            }
            Spacer()
            if source.transport == .local || source.transport == .probe {
                ChannelToggleChip(
                    label: "状态栏无感桥接",
                    tint: .teal,
                    isOn: source.bridgeStatusLine,
                    isDisabled: !source.isEnabled
                ) {
                    Task { await viewModel.setBridgeStatusLine(!source.bridgeStatusLine, for: source) }
                }
                .help("自动包装 Claude 与 agy 的 statusLine 以采集官方 5h/7d 额度与实时状态, 不注入生命周期 Hooks")
            }
        }
    }
}

private struct ChannelToggleChip: View {
    let label: String
    let tint: Color
    let isOn: Bool
    let isDisabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(isOn ? tint : .secondary.opacity(0.5))
                Text(label)
                    .font(.system(size: 11.5, weight: isOn ? .semibold : .regular))
                    .foregroundStyle(isOn ? .primary : .secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                isOn ? tint.opacity(0.12) : Color.primary.opacity(0.03),
                in: Capsule(style: .continuous)
            )
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(isOn ? tint.opacity(0.45) : Color.primary.opacity(0.09), lineWidth: 0.8)
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.5 : 1.0)
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
            return "提示: 先点击右上角「生成新读取密钥」, 下方命令会自动填入对应的 SHA-256 校验哈希"
        }
        return "已根据上方输入的读取密钥自动计算 SHA-256 哈希, 服务端仅保存哈希值"
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
        UsageDisclosure(title: "查看常驻中枢服务端部署说明 (无需安装 Codex / Claude / agy)") {
            VStack(alignment: .leading, spacing: 8) {
                Text("中枢机仅需 Python 3.9+ 与 Nginx TLS 反向代理 (关闭 /v1/events 的 proxy_buffering 以支持长轮询实时推送)")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary)
                Text(tokenHashNote)
                    .font(.system(size: 11.5)).foregroundStyle(.secondary)
                Text(serverCommand)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .usageCenterInset(cornerRadius: 8)
                Button {
                    PasteboardWriter.copy(serverCommand)
                    copied = true
                } label: {
                    Label(copied ? "已复制启动命令" : "复制启动命令", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 11.5, weight: .medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(.secondary)
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
            ControlCenterSectionHeader(
                title: "添加外部探针节点",
                subtitle: "生成独立单写密钥与一键安装命令, 无需配置 SSH 入站权限",
                symbol: "antenna.radiowaves.left.and.right",
                tint: .accentColor
            )
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
        .frame(width: 510, height: 440)
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
            ControlCenterSectionHeader(
                title: title,
                subtitle: "在目标机器终端执行以下单行命令即可完成下载, 鉴权配置写入与后台自启注册",
                symbol: "terminal.fill",
                tint: .accentColor
            )
            Text(command)
                .font(.system(size: 11.5, design: .monospaced))
                .textSelection(.enabled)
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .usageCenterInset(cornerRadius: 10)
            Text("安全说明: CODEXBAR_TOKEN 通过环境变量传给安装脚本并写入 0600 权限配置文件, 不会出现在 URL 查询参数或常驻进程命令行中")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
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
        .frame(width: 600)
    }
}
