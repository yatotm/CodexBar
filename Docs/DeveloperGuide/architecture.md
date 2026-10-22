# 整体架构

简体中文 | [English](../en/DeveloperGuide/architecture.md)

## 技术基线

CodexBar 使用 Swift 6、SwiftUI、AppKit，运行于 macOS 15+。唯一 scheme 包含主 App、root `CodexBarHelper`、无宿主 `CodexBarTests`。App 默认为 `MainActor` 隔离，磁盘、管道、socket 和 SQL 工作移出主线程。

## 进程与数据流

```text
每台机器
  Codex CLI / IDE ─ 官方共享 app-server
                       │ Unix socket
                       └ SharedCodexCollector.py ─ 本机任务快照与补充事件
  Claude Code ─ 本地 Hook / 日志 ─ ActivityCollector.py
  会话日志 ─ UsageCollector.py ─ 历史统计 / 请求级 Token / 额度证据

Mac CodexBar
  本机共享 socket ─ CodexStatusService ─ 账号 / 额度 / 重置卡
  本机管道 / SSH ─ RemoteActivityController ─ 合并任务显示
                           └ 本机 Codex ─ CodexActivityMonitor ─ 通知 / 防睡眠
  日志统计 / SSH / HTTPS ─ UsageCenterStore ─ 热力图 / 用量中心
  官方账号日明细 + 同账号日志 ─ 周期价值估算
  签名 XPC ─ root Helper ─ 固定睡眠控制 / 自动重置 wake 计划
```

共享后台的实际版本至少为 `0.162.0`。CLI 磁盘版本和运行后台版本独立展示；连接现有后台不要求重新启动 CLI。关闭 App 或重连不会结束后台及用户任务。端点明确缺失时才通过选定启动器运行 `codex app-server daemon start`

## 所有权与生命周期

| 对象 | 负责的状态 | 生命周期 |
| --- | --- | --- |
| 官方 Codex daemon | Codex 会话和账号 | 由官方 CLI 管理，App 不终止 |
| 共享采集器 | 脱敏任务快照、增量 Token 基线、补充权限/中断事件 | 各机器 launchd/systemd 管理 |
| `CodexStatusService` | 本机账号连接及短期缓存 | App 内 actor，只持有自己的 socket |
| `RemoteActivityController` | 每台机器、每个提供方的连接和代次 | 随睡眠门禁暂停、恢复 |
| `CodexActivityMonitor` | 本机 Codex 快照、通知与保护 | 接收共享采集器的可信快照 |
| `ActivityPresentationModel` | 全部/Codex/Claude 展示合并 | 不将远端任务注入本机电源控制 |
| `UsageCenterStore` | 历史来源、游标、去重查询 | 独立 SQLite actor |
| root Helper | 有界电源操作和恢复责任 | 不读取账号、任务或日志，不联网 |

采集器只订阅已确认加载的会话，不恢复历史会话、不修改模型与审批策略、不调用推理。Mac 离线时远端继续记账；恢复时读取当前快照和增量历史，不回放旧通知。

## 启动与退出

`CodexBarMain.main()` 先处理旧 `--hook-event` 调用，再取得按 bundle ID 隔离的单实例锁，最后进入 SwiftUI。Hook 子进程不初始化 UI，失败也不能阻断 Codex。

`CodexBarAppDelegate` 装配所有长期服务。新后台健康后撤除本应用的旧 Codex handler，保留 Claude、其他应用 Hook 和全部旧账本。历史 Hook 模式仅用于兼容旧配置及历史解析，不再自动安装或修复。

退出前先取消自动重置并等待评估清理，再收敛电源租约和 wake 计划。清理失败则取消退出，允许重试已下载更新的安装。

## 数据与恢复

- 账号、额度与历史相互独立；账户暂不可用时仍可显示本机和远端任务
- 共享实时库与旧 Hook、用量、价值数据库分开，不替换旧 schema
- 实时 Token 只用于任务显示；估值继续使用请求身份、模型、Fast、认证证据和实际重置周期
- 事件缺失表示未知，不能补成零；失联不代表任务完成
- 每个异步操作检查取消与代次，旧连接结果不能覆盖新连接
- 动画、定时刷新和公开服务状态随可见性及系统睡眠暂停；DarkWake 不恢复被显示睡眠门禁关闭的普通采集

## 入口

- [共享账户传输](../../CodexBar/Services/CodexStatus/CodexSharedSocket.swift)
- [各机实时采集器](../../CodexBar/Resources/SharedCodexCollector.py)
- [合并任务通道](../../CodexBar/Services/UsageCenter/RemoteActivityController.swift)
- [实时任务与保护](activity-monitor.md)
- [用量中心与估值](usage-center.md)
- [电源与自动重置](sleep-prevention.md)
- [上游逐项适配](upstream-adaptation.md)
