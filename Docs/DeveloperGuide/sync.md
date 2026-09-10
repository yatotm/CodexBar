# 多设备统计与旧云同步

简体中文 | [English](../en/DeveloperGuide/sync.md)

本 fork 已移除 CloudKit 服务、权限、设置和菜单状态。原 `WorkflowSyncService` 不再构建或运行；本机维护由 `WorkflowMaintenanceScheduler` 串行调度，仍支持原始 Hook 记录重建。

本地 JSONL 格式、计数字段及聚合 schema 不变。旧 `HookEvents/Sync` 缓存和旧偏好保留但不读取，不向原云端容器发送删除请求。

跨设备数据改由既有 [用量中心](usage-center.md) 的 SSH/HTTPS 协议处理。它不向实时任务、防睡眠或自动重置提供远程任务状态。
