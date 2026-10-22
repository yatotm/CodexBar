# 旧 Hook 历史与聚合

简体中文 | [English](../en/DeveloperGuide/hook-and-aggregation.md)

## 当前边界

Codex 实时采集已切换到共享后台，最低实际版本为 `0.162.0`。旧 Codex Hook 不再安装或自愈；新后台确认健康后只撤除 CodexBar 自己的 handler，其他应用和用户配置保留。Claude 的本地 Hook 继续使用。

本文说明保留的旧数据，不是新安装流程。当前任务链路见 [实时任务监控](activity-monitor.md)

## 兼容入口

旧配置可能仍调用 App 的 `--hook-event`。它在单实例锁和 UI 初始化前分流，从 stdin 有界读取，提取元数据，在 `flock` 锁中追加 JSONL 后立即退出。失败不阻断 CLI。

`SessionEnd`、`Interrupt` handler 的原超时为 3 秒，其他事件为 5 秒，等锁预算比 handler 超时少 2 秒。不在该模式创建网络连接、窗口或长期服务。

## 存储与保留

```text
~/Library/Application Support/CodexBar-yatotm/HookEvents/
  events/YYYY-MM-DD.jsonl
  daily.jsonl
  maintenance.json
  stats.lock
  Sync/
```

原始事件和日聚合保留 210 天，聚合中的明细身份只保留 3 天。旧 `Sync/` 数据不读、不上传，也不主动删除。

`WorkflowService` 在后台增量维护历史。JSONL 半行留到下一轮，损坏行有界跳过，文件替换与截断通过来源身份识别。源文件仍在保留期时可完整重建；没有原始数据时不能编造历史计数。

## 聚合约束

当前 `WorkflowMaintenanceState.currentAggregationSchema` 为 `9`。改变旧事件聚合算法、字段语义或去重规则，须递增 schema，从保留期原始 JSONL 全量重建，不增加字段级迁移。

计数字段缺失代表旧来源没有提供，不能按明确的零解码。会话、轮次、工具、子任务与中断各自按原身份规则去重；已经压缩身份的日期收到迟到事件时，重新读取原始日志，不能盲目相加。

## 新数据

`UsageCollector.py` 从会话日志持续统计 Token、模型、轮次、工具、压缩、子任务和时长。共享采集器只补权限请求和中断，保存在独立库后按固定 ID 导入既有用量记录。它们不进入旧 Hook 聚合，也不会触发 schema `9` 重建。

热力图优先显示已收集的设备日志；无设备日记录时仍可显示旧 Hook 历史。旧文件和价值账本均保留，查看历史不要求当前 CLI 满足新版本门槛。

## 回归

覆盖并发追加、锁超时、半行、损坏行、来源替换、压缩后迟到事件、schema 重建、缺失计数，以及只删除本应用 handler。新的共享事件另测重复导入、目录隔离和原账本不变。
