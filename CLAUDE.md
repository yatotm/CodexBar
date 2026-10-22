# CLAUDE.md

写作、兼容性、验证与 Git 规则遵循 [AGENTS.md](AGENTS.md)

## 项目与构建

这是 `yatotm/CodexBar`，面向 macOS `15+` 的 Swift `6` 菜单栏应用。保留上游原生 UI，增加 Claude、多机器统计和 Codex 周期价值估算，没有 iCloud 同步。

只有 `CodexBar` scheme，包含 App、`CodexBarHelper`、无宿主 `CodexBarTests` 三个 target。默认隔离为 `MainActor`；I/O 放在 actor、后台线程或独立采集进程。

```sh
bash Scripts/test-local.sh
bash Scripts/verify-usage-center.sh
bash Scripts/test-helper.sh
python3 -B -m unittest discover -s Tests -p 'test_shared_codex_collector.py'
swiftformat .
swiftlint
```

日常打包用 `Scripts/build-local.sh`，沿用 `io.github.yatotm.codexbar.build` 域的 `signingIdentity`。不要用临时签名覆盖开发签名。通过 `CODEXBAR_LOCAL_OUTPUT`、`CODEXBAR_TEST_OUTPUT` 将产物放到项目外的临时目录，验证后清理。

Debug 与 Release 的 bundle ID 分别为 `io.github.yatotm.codexbar.debug` 和 `io.github.yatotm.codexbar`，helper 对应追加 `.helper`。正式安装在 `/Applications/CodexBar.app`。创建 tag、推送或发布需本次用户授权。

## 启动分流

`CodexBarMain.main()` 先处理 `--hook-event`，再取得 `AppInstanceLock`，最后进入 SwiftUI。锁按 bundle ID 隔离，不传给子进程。旧 Hook 调用仍快速写入 JSONL 并退出，不初始化 UI，也不因 App 已运行而丢事件。

`CodexBarAppDelegate` 是长期服务装配点。普通启动不再安装或修复 Codex Hook；新采集器健康后仅撤除自己的旧 handler，保留原始日志、聚合、偏好与其他应用配置。

## 三条数据链路

| 链路 | 来源 | 边界 |
| --- | --- | --- |
| 账号、额度、重置卡 | 本机共享 app-server | 实际握手版本至少 `0.162.0`，自动重置只相信新鲜账户响应 |
| 实时任务 | 各机器共享后台、Claude 本地 Hook | 只传白名单元数据，Mac 经管道或 SSH 接收 |
| 历史与估值 | 会话日志、旧 Hook 聚合、官方账号日明细 | 请求级去重和认证归属独立维护；实时任务 Token 不入价值账本 |

### 共享后台

`CodexSharedSocket` 与 `SharedCodexCollector.py` 连接 `$CODEX_HOME/app-server-control/app-server-control.sock`。账户仍由 `CodexStatusService` 提供，自动重置请求共用 `AppServerRequestBudget` 的单调截止时间。

只有端点明确缺失时才用选定 CLI 启动官方 daemon。重连、切换启动器和退出 App 都不能停止共享后台。旧 App 专用代理偏好保留供回退，当前网络环境由官方后台管理。

采集器只订阅 `thread/loaded/list` 和 `thread/read` 确认已加载的会话，不恢复历史会话、不自动批准、不发模型请求。快照与补充事件保存到独立 SQLite 库，不迁移旧数据库。

### 任务、恢复与电源

`RemoteActivityController` 按机器及提供方维护独立连接与健康状态。一台机器的 Codex 断线不能影响 Claude。

本机 Codex 交给 `CodexActivityMonitor.receiveSharedTasks`，统一驱动本机通知、触觉与防睡眠。`ActivityPresentationModel` 合并所有来源，标签只过滤面板，菜单栏图标始终汇总全部任务。远端任务不控制本机电源。

主任务等待子 Agent 时仍为运行中；审批或明确阻塞的提问才进入等待状态，异步问题只显示待回应数量。元数据顺序为模型、思考深度、机器名。未知 Token 不填零，恢复的历史终态不重播提醒。

`SystemConnectionGate` 在睡眠或合盖且无工作外屏时断开连接，物理屏、虚拟屏和镜像屏统一处理。DarkWake 不解除显示器恢复门槛。远端继续记录，Mac 恢复后静默对账。

### 历史与价值

`UsageCollector.py` 仍增量解析 Token、模型、Fast、认证归属。共享采集只补权限请求、中断事件，固定 ID 幂等导入，不重复加入 Token、工具、轮次。

旧 Hook 原始记录和聚合保留 `210` 天，schema 为 `9`。`WorkflowService` 可重建旧历史，不能把新共享事件当旧 Hook 回放。改变原始 Hook 聚合语义仍须递增 schema。

价值以本机 OAuth 账号为范围。官方明细完整时采用官方数据，缺失时整段使用同账号设备日志；补齐后整段替换，不能相加。按实际重置划分周期，不能按预计时间提前分段。

## 防睡眠与自动重置

防睡眠为关闭、手动、随任务三种模式。手动模式不依赖任务，随任务只消费本机可信状态。断线和状态待确认不阻止睡眠。

App 的 IOPM 断言处理空闲睡眠，签名 helper 的固定 `pmset` 操作处理合盖睡眠。保留 helper 身份、授权、所有权 schema、XPC 与 wake owner，不增加独立管理 App。更新时只恢复自己取得且无有效租约的电源状态。

自动重置默认关闭。每张凭证独立限制重试预算，取消后等待清理，再开始新评估。消费前再次检查账号身份、幂等键及过期前 `60` 秒的截止时间；测试不得调用真实重置。

异常任务保护只处理本机可信运行中任务，心跳不算进展，恢复后无通知对账。新旧任务沿用同一保护哈希，`ActivityProtection/state.json` 仍为 schema `1`，只含哈希与时间戳。

## UI 与性能

保留 `NSPopover` 与备用 `NSPanel`，AppKit 固定顶边调整窗口高度，不叠加逐帧 SwiftUI 高度动画。额度入场动画独立保留；任务文字不使用持续闪动或粒子。

任务时间线只在可见时更新，卡片自行订阅任务变化。日志 JSON 格式化、高亮和 TextKit 排版移到后台，取消后不提交旧结果，内存日志保持有界。

设置子面板共享焦点、撤销栈与 `SettingsOptionsPanelController`。首次展示、点击区域、收缩文字清理和窗口焦点需手动验证。见 [UI 与生命周期](Docs/DeveloperGuide/ui-and-lifecycle.md)

## 隐私与外部交互

- Claude 不主动访问 Anthropic；状态栏只包装已有命令，失败不阻塞 CLI
- 公开 Codex 服务状态不带凭据，面板可见时随额度刷新
- SSH 不转发 Agent、不自动接受主机密钥、不开放公网端口
- 不记录 OAuth token、对话正文、工具参数或输出；系统日志只写结果、计数、时间
- Sparkle、更新日志及发布通道使用 fork 地址，保留上游署名与 GPL 许可

架构及本次审查见 [开发者指南](Docs/DeveloperGuide/README.md) 和 [上游更新审查](Docs/DeveloperGuide/upstream-adaptation.md)
