# 实时任务监控

简体中文 | [English](../en/DeveloperGuide/activity-monitor.md)

## 数据来源

Codex 的正式运行路径使用每台机器自己的共享后台，最低实际版本为 `0.162.0`。`SharedCodexCollector.py` 先读取 `thread/loaded/list`，经 `thread/read` 确认仍已加载后，才用 `thread/resume(excludeTurns: true)` 订阅。不能为统计恢复历史会话。

Claude 继续使用 `ActivityCollector.py` 和原生日志/Hook，不请求 Anthropic。两者在 Mac 复用同一任务卡片、任务中心、机器标签和通知外观。

Claude 的 `Stop` 和 `SubagentStop` 可通过 `background_tasks` 报告仍在执行的 shell。采集器把它归到原会话，单独统计子 Agent 和审批。连接或保活时，只读当前 Claude 配置目录下的 `sessions/<pid>.json`，按会话、机器、PID 和进程启动时间核对。已提前完成的记录可以按 `shell` 状态恢复，主会话重新工作或空闲时再切换阶段。传到 Mac 的只有任务阶段，不包含命令或输出。[Claude Stop Hook](https://code.claude.com/docs/en/hooks#stop-input)

## 快照与连接

无 Hook 探针按主转录中的用户输入、轮次结束和后台任务回执确定 Claude 任务的起点。后台命令唤醒同一轮时沿用原起点，完整空闲后重新计时。后台作业的本地时间线可补充完成边界。转录游标和未结束任务的摘要只在内存中保留，缺少可靠起点时通过 `lifecycleComplete` 隐藏时长。

`RemoteActivityController` 的连接键包含来源 ID 与提供方。同一机器的 Codex 和 Claude 有独立的健康状态、重试与代次；某一端失败不能把另一端标为失联。

帧保留 `schema=1`、`epoch`、`revision`、`sentAt`，新增字段均为可选。共享来源明确提供 `backend=sharedCodex`、`sourceAvailable` 和实际 `serverVersion`。最多接收 500 条任务、512 KiB 一帧；ACK、版本顺序与字段长度均校验。

共享采集器的独立库在 `~/.local/state/codexbar-shared-codex/shared-activity-v1.sqlite`。只保存白名单快照、哈希身份、计数和时间，不保存正文、工具参数、输出或逐 Token delta。通知文件用于唤醒阻塞的流读取，空闲流每 60 秒保活。

新变化合并落盘，空闲时不反复写同一快照。已加载列表每 5 秒核对；活跃任务补查有每轮时间预算，空闲会话至少间隔 60 秒。

`thread/closed`、`thread/archived` 和 `thread/deleted` 会撤下该线程的活动状态，保留已采集的历史与仍有活动的关联子任务。`thread/reverted` 先把受影响轮次标为待确认，读取回退后的轮次列表后再撤下已消失的轮次。跨越这些事件才返回的读取结果会丢弃。恢复的主任务按 `threadId` 和 `turnId` 匹配自身用量，子任务另行核对 `rootTurnId`。

只有 RPC 错误码为 `-32600` 且 `data.type` 为 `modelProviderMismatch`、`modelProviderNotConfigured` 或 `modelProviderPolicyConflict` 时，才将该会话作为提供方不可用单独重试。已知受影响的任务显示待确认，其他已经核对的会话继续更新。

## 任务归属与等待语义

根 thread 与根 turn 共同决定任务身份。子 Agent 汇总在主任务内，等待子 Agent 时主任务仍属于运行中。自动审核代理不成为主任务，也不延长其防睡眠时间。

| 输入 | 展示 |
| --- | --- |
| 思考、回复、工具、压缩 | 运行中及当前阶段 |
| 命令/文件权限审批 | 等待批准 |
| 明确阻塞的用户提问 | 等待回应 |
| 异步问题 | 保持运行，显示待回应数量 |
| 父轮结束但子任务仍在工作 | 运行中，显示子任务数量 |
| 来源失联或生命周期不确定 | 状态待确认 |
| 明确完成/中断 | 最近完成/终止 |

普通用户消息收起非阻塞问题。专用回答先验证结构和问题标识，只收起匹配题目；正文仅瞬时解析，不持久化。计划进度和最近工具结果使用紧凑行或悬浮说明，模型、思考深度、机器标签保持原顺序。

## 本机状态与副作用

本机 Codex 帧交给 `CodexActivityMonitor.receiveSharedTasks`，统一发布通知、触觉和电源状态。`ActivityPresentationModel` 只合并展示，不重复计算本机任务，也不把远端任务交给本机防睡眠。

共享帧的可选 `reconciliationComplete` 区分连接健康与线程核对完成。核对未完成时暂停异常任务判定和实时通知，按线程退避重试；明确标记为 `thread_title` 的内部线程不参与任务。旧帧缺少该字段时沿用原行为，schema、身份和存储位置不变。

首次或重连时只恢复基线。只有此前可信运行的任务实时到达终态，才可发通知或流光。历史终态由 `isHistoricalTerminal` 抑制，完成和终止记录保留 10 分钟。

结束时间优先使用后台的明确时间；缺失时保留首次确认的时间，重复轮询和迟到的 Token 统计不能延长展示期限。后续收到明确结束时间时仍可修正。没有已有任务或结束时间的历史终态不生成新记录。

实时 Token 只显示有明确基线的计数，不加入历史价值账本。生命周期不完整时不伪造精确耗时。

## 休眠与异常保护

`SystemConnectionGate` 在睡眠或合盖且无活跃外屏时关闭 Mac 管道和 SSH；外屏、虚拟屏、镜像屏按工作状态判断。DarkWake 不解除显示睡眠门槛。远端采集器继续记录；Mac 恢复后的第一帧静默对账。

断线时本机任务转为待确认，停止按任务防睡眠和异常静默判定，不制造终止记录。恢复只有新健康帧才能解除暂停，旧代次回调一律丢弃。

保护阈值仍为 30 分钟、1、2、4 小时。只有可信的本机运行任务参与，审批等待不参与。心跳只刷新覆盖时间，不改变 `lastProgressAt`。保护哈希沿用旧公式，`ActivityProtection/state.json` schema 保持为 `1`，最长保存 24 小时。

## 历史兼容与验证

旧 `HookEventTailReader` 和 rollout 状态机保留为历史兼容与回归依据，生产装配明确使用 `usesSharedBackend: true`，不维护第二套实时 Codex 来源。

验证包括主子任务归属、异步/阻塞问题、审核代理排除、心跳不算进展、来源失联、历史终态静默、本机/远端分工、保护哈希兼容。实际睡眠、外屏工作和 DarkWake 还需硬件交互验证。
