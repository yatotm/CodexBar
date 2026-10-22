# 开发与验证

简体中文 | [English](../en/DeveloperGuide/development.md)

## 环境与构建

需要 macOS 15+、Xcode、Swift 6、`swiftformat` 和 `swiftlint`。唯一 scheme 为 `CodexBar`，包含 App、`CodexBarHelper` 和无宿主 Swift Testing target `CodexBarTests`。

```bash
xcodebuild -project CodexBar.xcodeproj -scheme CodexBar -destination 'generic/platform=macOS' build
swiftformat .
swiftlint
```

格式配置见 `.swiftformat`，使用 Swift 6 和 4 空格缩进。`swiftlint` 只检查 `CodexBar/`，不覆盖 `Shared/`、`CodexBarHelper/` 和 `Scripts/`

修改前检查 `git status --short`。已有未提交改动时，仅格式化本次涉及的 Swift 文件，或使用 `swiftformat --lint . --cache ignore` 检查。`swiftlint --no-cache` 可避免写入缓存。

日常构建不需要 Developer ID 或公证凭据。写作、Git 和兼容性规则见 [AGENTS.md](../../AGENTS.md)

## 修改入口

| 功能 | 主要位置 | 实现说明 |
| --- | --- | --- |
| 共享 app-server、自动重置 | `Services/CodexStatus` 与对应 Settings | [app-server 数据链路](app-server.md) |
| 旧 Hook 历史 | `CodexHookSettings`、`WorkflowService`、聚合模型 | [Hook 采集与历史聚合](hook-and-aggregation.md) |
| 实时任务与异常保护 | `SharedCodexCollector.py`、`RemoteActivityController`、`CodexActivityMonitor` | [实时任务监控](activity-monitor.md) |
| 防睡眠与系统唤醒 | `KeepAliveController`、`AutoResetWakeScheduler`、helper | [防睡眠系统](sleep-prevention.md) |
| 通知与音效 | `CodexNotificationService`、通知 Settings | [通知系统](notifications.md) |
| 同步 | `UsageCollectorClient` 与本地维护调度器 | [多设备统计边界](sync.md) |
| 菜单、窗口、快捷键 | `Controllers` 与对应 View | [UI 与应用生命周期](ui-and-lifecycle.md) |

长期对象由 `CodexBarAppDelegate` 装配。新增状态优先放入现有所有者，View 消费快照并发出操作意图。源码阅读入口见 [整体架构](architecture.md)

## 变更检查

涉及持久化 key、schema、身份计算、最低系统版本或新旧版本共存时，先说明影响和可选兼容方案，等待用户选定。新增网络访问、日志字段时核对 [数据与隐私边界](data-and-privacy.md)

聚合算法、输出字段含义或去重规则变化时，递增 `WorkflowMaintenanceState.currentAggregationSchema`，从保留期内原始 JSONL 完整重建，不增加字段级历史迁移。

异步修改需要检查取消、结果提交时的资格和 generation。跨进程文件仍使用 `flock`；actor 只保护单进程。`@Published` 订阅使用闭包的新值参与判断，避免 `willSet` 阶段回读旧属性。

## 验证流程

1. 检查修改范围，确认未覆盖已有工作
2. 格式化并运行 `swiftlint`
3. 构建 App 与 helper
4. 手动验证受影响的正常、失败和恢复流程
5. 检查文档及 `git diff --check`

构建失败时先定位第一条实际 `error:`。签名或 entitlement 错误要核对 Debug/Release 身份；helper 协议修改同时检查两个 target 与 `Shared`。编译和静态检查不覆盖窗口焦点、系统授权或硬件电源行为。

纯文档修改运行格式检查、lint 和构建，并检查相对链接与中英文内容。

### 手动场景

| 改动范围 | 重点场景 |
| --- | --- |
| 菜单与窗口 | 快速开关、淡出中重开、popover/fallback、多屏与 Space、设置和日志焦点、通知点击和快捷键 |
| Hook 与聚合 | 保留已有 handler、最低版本、并发追加、半行和损坏行、文件替换与截断、完整重建 |
| 实时任务 | 首次与重连不补通知、阻塞/异步问题、子任务归属、独立来源健康、唤醒恢复 |
| 通知 | 授权拒绝与恢复、阈值跨越、同周期去重、任务恢复撤回、声音缺失 |
| 共享后台 | 已运行后台连接、端点缺失启动、实际最低版本、取消与截止时间、退出不影响 CLI |
| 同步 | SSH/HTTPS 多设备合并、断网恢复、本机重建 |
| 系统电源与 helper | 首次授权、任务运行/等待切换、低电量、时长上限、外部睡眠来源、异常退出与重启 |
| 自动重置唤醒 | 计划替换、关闭与退出清理、连接中断、helper 重启、注销前清零、到点重新读取 |

helper 改动还需检查 App 包内可执行文件和 plist 的位置、签名与注册指纹。各专题末尾列出更细的状态转换场景。

记录验证使用的构建、前置设置、操作序列、实际结果和相关日志，便于复现。

### 性能验证

CPU、内存、唤醒、磁盘活动与采集环境见[上游性能报告](https://codexbar.zabrian.app/performance)

结果对应报告中记录的构建和测试场景。采集、生成报告和基线对比方法见[性能采集工具说明](../../Scripts/performance/README.md)

## Debug 与 Release

| 配置 | App bundle ID | Helper bundle ID |
| --- | --- | --- |
| Debug | `io.github.yatotm.codexbar.debug` | `io.github.yatotm.codexbar.debug.helper` |
| Release | `io.github.yatotm.codexbar` | `io.github.yatotm.codexbar.helper` |

App 偏好和系统授权按身份隔离，Hook 数据与异常会话保护文件共享。排查时确认正在运行的 App、helper 和已安装 Hook 的可执行路径。

## 日志

Release 系统日志：

```bash
/usr/bin/log stream --predicate 'subsystem == "io.github.yatotm.codexbar"' --style compact
```

Debug 使用 `io.github.yatotm.codexbar.debug`，helper 的 subsystem 使用对应 helper bundle ID。

App 内日志窗口保留最近 500 条 app-server 交互。日志预览排版在后台，格式化取消与窗口关闭后不提交旧内容。

| 问题 | 查看内容 |
| --- | --- |
| 额度未刷新 | handshake、method、retry、stale |
| 实时后台不可用 | 实际 daemon 版本、socket、监听器服务、连接健康与 SSH 状态 |
| 任务未结束 | 根轮次、共享状态对账、连接代次与数据源健康 |
| 同步缺数据 | 来源配置、SSH、epoch/cursor、增量日志与保留期 |
| 通知未出现 | authorization、kind、duplicate、obsolete |
| 防睡眠未生效 | block reason、helper 注册、XPC generation、source |
| 自动重置未执行 | target、threshold、retry window、wake schedule |

日志使用 `LogTrigger`、`LogDuration` 和 `LogFields.joined`，记录阶段、分类、计数及耗时。请求内容和身份信息的限制见 [数据与隐私边界](data-and-privacy.md)

## 发布与清理脚本

| 脚本 | 用途 |
| --- | --- |
| `Scripts/build.sh` | Release archive、Developer ID 导出、公证、staple 与 Gatekeeper 校验 |
| `Scripts/dmg.sh` | 打包 DMG |
| `Scripts/appcast.sh` | 签名更新并生成 appcast |
| `Scripts/cleanup.swift` | 注销 helper；先退出所有 CodexBar 实例，`--check` 只检查，`--debug` 或 `--release` 限定范围 |

发布脚本需要签名和公证凭据，不用于日常验证。版本号从 [`Version.xcconfig`](../../Config/Version.xcconfig) 读取。

helper 清理先取消并确认系统唤醒计划清零，再注销服务；失败时停止。详细行为见 [防睡眠系统](sleep-prevention.md)

## fork 验证入口

本地使用 `bash Scripts/build-local.sh` 构建独立 Debug App，执行 `bash Scripts/verify-usage-center.sh` 检查采集、账号隔离、提前重置、窗口展开和睡眠取消。迁移与发布边界另有 Python 回归检查，入口见 [构建与独立发布](releasing.md)

菜单手动验证应覆盖全部标签之间的切换、关闭后重开、设备展开收起及侧边详情清理。改名后的 Helper 还需在有正式签名时验证首次授权、等待/运行切换、唤醒计划清理及异常退出恢复；ad-hoc 构建通过不代表这些系统能力已验证。

## 本地开发签名

`Scripts/build-local.sh` 优先读取环境变量，其次读取本机保存的签名身份；都未配置时使用临时签名。CI 不读取本机偏好。有可用 Apple Development 证书时，可显式使用同一身份签署主 App、框架与电源组件，并开启 hardened runtime：

```bash
CODEXBAR_SIGNING_IDENTITY="Apple Development: 你的证书名称" \
CODEXBAR_BUILD_CONFIGURATION=Release bash Scripts/build-local.sh
```

证书从 Xcode 的 Apple Accounts 页面管理。签名失败不会回退成看似具备权限的包；主 App 仍按实际签名和后台授权状态决定防睡眠是否可用。本地开发签名不等同于 Developer ID 公证，也不自动证明公开分发场景已通过验证。

本轮实时任务回归覆盖短帧读取、合并身份、标题顺序、标签筛选、断线状态隔离、Hook 配置保留及工具、压缩、子智能体事件。Apple Development 构建已在本机验证首次后台授权、手动与随任务模式、关闭和退出恢复，以及同身份更新后的授权保留。物理合盖、DarkWake 和重新开盖仍需单独实测。

本机可以保存证书指纹，后续构建自动沿用，不保存或导出私钥：

```bash
defaults write io.github.yatotm.codexbar.build signingIdentity -string "证书 SHA-1 指纹"
```

`CODEXBAR_SIGNING_IDENTITY=-` 可显式构建临时签名包。证书不可用时构建失败，不静默降级。异常退出恢复已实测，本次强制结束 App 后约 16 秒恢复系统睡眠设置。

## 本机打包并发布

需要保留电源功能时，使用已配置开发签名的 Mac 构建，再运行 `Scripts/package-release.py --keychain-account yatotm.CodexBar`。打包器验证主 App 与电源组件的签名身份及双架构，直接通过钥匙串签署 Sparkle 更新，不导出私钥。

确认发布后，推送对应提交，并用 `Scripts/publish-release.py` 创建附注 tag、上传附件和公开 Release。普通推送只运行验证。GitHub 托管构建未配置开发签名时仍生成临时签名包，其电源功能不可用，不能替代本机的开发签名产物。

## 隔离单元测试

`bash Scripts/test-local.sh` 在临时工程副本中运行无宿主 Swift Testing，构建输出位于 `~/Library/Caches/CodexBar/TestBuild`，可用 `CODEXBAR_TEST_OUTPUT` 指定。测试数据和偏好使用独立临时目录与 suite，不触发真实服务。原多机器回归入口保持不变；Bark 使用 `python3 -B -m unittest discover -s Tests -p 'test_issue_notification.py' -v` 做模拟验证，不发送真实通知。

## GitHub Issue 的 Bark 通知

工作流仅处理本仓库的新 Issue、他人 Issue 评论和手动测试，跳过本人事件及 PR 评论。它不在 Mac 后台运行，也不改变应用通知设置。

在仓库 `Settings > Secrets and variables > Actions` 配置：

| Secret | 内容 |
| --- | --- |
| `BARK_TOKEN` | Bark 设备密钥，不是完整推送链接，必填 |
| `BARK_SERVER_URL` | 自建服务器的 HTTPS 根地址，可选；默认 `https://api.day.app` |
| `BARK_ICON_URL` | 通知图标的 HTTPS 地址，可选 |

`SELF_LOGIN` 仓库变量可指定需要排除的账号，默认使用仓库所有者。缺少设备密钥时跳过发送；配置完成并推送工作流后，可在 Actions 手动运行 `Issue notification` 验证。发送内容为 Issue 标题和链接，设备密钥通过 HTTPS POST 请求体传送，不写入 URL 或日志。

共享协议测试用 `python3 -B -m unittest discover -s Tests -p 'test_shared_codex_collector.py'`，Helper 隔离测试用 `bash Scripts/test-helper.sh`。它们不得调用真实模型、修改系统电源或消费真实重置卡。
