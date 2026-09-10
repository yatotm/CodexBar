# 数据与隐私边界

简体中文 | [English](../en/DeveloperGuide/data-and-privacy.md)

## 数据分类与信任边界

| 数据 | 处理方式 |
| --- | --- |
| 对话正文、工具参数和输出 | 不写入 Hook 文件或统计导出协议 |
| 会话身份与完整路径 | 仅在必要的本机读取中使用，远端导出使用哈希身份并排除完整路径 |
| 项目显示名、模型、时间、Token 和额度 | 允许进入用量中心协议，属于应告知用户的统计元数据 |
| OAuth 与统计服务令牌 | 不写日志、测试 fixture 或 Git；不传给其他统计设备 |

外部输入包括 Hook stdin、rollout、app-server 响应和远端统计数据，均需限制读取量并校验结构。业务服务运行在普通用户权限下；root Helper 只接受固定电源操作，不读取账户或日志、不访问网络。

本 fork 已删除 CloudKit 客户端和 entitlement。不存在上传原生 iCloud 私有数据库的路径。

## 本地读取

app-server 通过 stdio 提供本机账户、额度、Token 和重置券。请求日志保存规范化的完整请求和响应，最多 500 条，只存在当前进程内存。它可能包含账户、重置券 ID 和幂等键，不能当作脱敏摘要。

Hook recorder 只提取时间、事件、来源分类、模型、工具名和必要的身份上下文。原始 Hook JSONL 可以包含 `cwd`，属于本地敏感数据，受保留期和权限约束。rollout 元数据读取有总量预算，不能扩大为任意文件访问。

## 用量中心与官网分析

原始 JSONL 在日志所在设备解析，SQLite 保存筛选后的事件与游标。Codex OAuth/API 身份按记录的提供商和认证上下文判断，不能把当前登录方式套用到全部历史。Claude 只读取已有日志和缓存，不主动请求 Anthropic。

官网分析使用本机 Codex OAuth，只访问固定的官方主机，拒绝重定向并限制超时、响应大小。凭据仅在本机认证与请求中使用，不自行刷新或改写，也不发送给 VPS。账号切换通过 generation 丢弃迟到结果，缓存按账号哈希隔离。

HTTPS 来源使用系统证书校验和专用令牌，钥匙串服务名为 `io.github.yatotm.codexbar.usage-center`。SSH 保留主机密钥校验，只执行固定的采集、导出命令。完整协议见 [用量中心实现与验证](usage-center.md)

## 本地持久化

```text
~/Library/Application Support/CodexBar-yatotm/
  HookEvents/events/YYYY-MM-DD.jsonl
  HookEvents/daily.jsonl
  HookEvents/maintenance.json
  HookEvents/stats.lock
  ActivityProtection/state.json
  UsageCenter/center-v1.sqlite
  UsageAnalytics/
  UsageQuotaHistory/
```

Hook 原始事件和日聚合保留 210 天，日聚合身份明细保留 3 天。异常会话保护仅保存哈希身份和时间，最长保留到最后进展后的 24 小时，匿名任务不写入该状态。

来源配置、菜单布局、代理和额度参考保存在 UserDefaults。代理密码仍以明文保存在 `CodexProxy.configuration` 中，关闭代理保留配置，删除配置或关闭认证后保存会清除密码。

Debug 与 Release 的偏好域分别为 `io.github.yatotm.codexbar.debug` 和 `io.github.yatotm.codexbar`，共享的本地数据通过进程锁和稳定 schema 协调。改变字段含义、身份计算或持久化结构前需要确定兼容策略。

旧 `HookEvents/Sync` 目录与 `WorkflowSync.*` 偏好不再读取，也不主动删除。首次迁移跳过这些缓存；本次移除云同步不更改 Hook 原始聚合 schema，不触发无必要的历史重建。

## 网络访问

| 目标 | 用途 |
| --- | --- |
| Codex app-server 子进程 | 官方认证、当前额度和重置操作 |
| 官方 `chatgpt.com` | 日级账号分析和额度核对 |
| 用户配置的 SSH/HTTPS 来源 | 经过筛选的统计元数据 |
| 本 fork 的 GitHub 更新源 | Sparkle 更新 |

Helper 不联网。代理只交给本 App 启动的 Codex 服务，不修改系统网络或其他应用。

## 日志、文件与恢复

系统日志仅记录阶段、分类、非敏感计数和定位信息，不记录 OAuth、正文、完整项目路径、会话 ID 或账户额度明细。

Hook 文件通过锁协调，只追加完整 JSONL 行；聚合可从原始记录重建。异常保护文件为 `0600`，用量缓存目录为 `0700`。SQL 参数使用绑定，取消与过期结果不得覆盖当前状态。

Helper 的 root 恢复状态位于 `/Library/Application Support/CodexBar-yatotm/helper-state.json`，由 root 管理，先持久化恢复责任再修改系统睡眠状态。它不是用户偏好，迁移工具不复制该文件或接管旧 Helper 的唤醒 owner。

## 验证重点

- 合成正文和工具参数不得进入 Hook 持久化或统计导出
- 缺失计数字段保留缺失语义，不能解码成明确的零
- 账号和来源切换不能串用缓存或接收迟到结果
- 本地 JSONL、SQLite 和偏好迁移保留原数据
- App 及依赖不得链接或请求 CloudKit，设置和菜单不再显示云同步入口

关键实现见 [WorkflowService](../../CodexBar/Services/Workflow/WorkflowService.swift)、[UsageCollectorClient](../../CodexBar/Services/UsageCenter/UsageCollectorClient.swift) 与 [UsageAnalyticsClient](../../CodexBar/Services/UsageCenter/UsageAnalyticsClient.swift)
