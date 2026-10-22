# app-server 数据链路

简体中文 | [English](../en/DeveloperGuide/app-server.md)

## 职责与连接所有权

账户链路读取 Codex 账户、套餐、额度、Reset Credits 和可用的服务端用量，并提供配置读写能力。实时任务使用独立的采集连接；Claude、本机与远程日志、官方分析和价值账本仍各自维护，不把账户快照写成任务历史。

```text
Codex 共享后台
  -> 本机 Unix socket / WebSocket
  -> AppServerSession
  -> CodexStatusService actor
  -> CodexQuotaSnapshot
  -> CodexStatusViewModel
  -> 菜单栏与主面板
```

`CodexStatusService` 只拥有客户端 socket 和同账户缓存，**不拥有共享后台进程**。关闭 App、切换来源、连接到期、取消请求或连接失败时，都只断开自己的连接，不发送停止后台、关闭线程或中断任务的命令。

每台远端机器的采集器连接该机器的后台，再通过现有 SSH 通道回传。Mac 的本地 socket 不会直接提供其他机器的会话。

## 连接位置与启动器

控制端点位于：

```text
$CODEX_HOME/app-server-control/app-server-control.sock
```

未设置 `CODEX_HOME` 时使用真实用户主目录下的 `~/.codex`。先尝试连接已有端点；只有明确收到 `ENOENT` 或 `ECONNREFUSED` 时，才允许调用：

```bash
codex app-server daemon start
```

权限错误、协议错误和握手超时不能触发后台重启。启动命令使用 `BoundedProcess`，启动与就绪检查共享最多 15 秒的预算；取消或超时只清理本次启动器进程，不终止它派生的共享 daemon。启动器输出不展示、不写入请求日志。

`CodexCLIResolver` 用于寻找启动器和读取磁盘版本：

- 自动选择优先使用全局 CLI，其次使用 `ChatGPT.app` 或旧名 `Codex.app` 内置 CLI
- Finder 环境补充 Homebrew、npm、Volta 等常见目录，并归一化真实用户主目录和符号链接
- App 内置入口优先读取 `codex-cli/codex-package.json`，清单上限 64 KiB，入口不能逃出 CLI 包目录；没有有效清单时兼容旧路径
- 用户选择只决定后台尚未启动时使用的启动器，不替换已运行的共享后台
- 已有端点可以在磁盘 CLI 缺失时继续连接

设置页分别展示磁盘启动器版本、实际后台握手版本和 socket 路径。最低版本检查只认握手返回的 `userAgent`，要求 **Codex `0.162.0+`**。升级磁盘 CLI 或重新连接客户端，不代表共享后台已经升级；后台寿命由 Codex 管理。

旧 `CodexProxy.configuration` 偏好保留，但共享连接不使用 App 专属代理。网络代理应在 Codex 自身的环境或配置中设置，不能为一次额度查询重配其他客户端共用的后台。

## 协议与超时

建立 Unix 连接后校验对端 UID，再完成 WebSocket 握手。握手校验状态码、`Upgrade`、`Connection` 和随机 challenge 的响应，响应头限制为 16 KiB。单条消息默认限制为 8 MiB。

```text
连接 socket
  -> WebSocket upgrade
  -> initialize(clientInfo)
  -> 校验实际后台版本
  -> initialized
  -> account/read(refreshToken: false)
  -> 提交已初始化的账户连接
```

客户端帧必须掩码；接收端支持分片文本和片段之间的 ping/pong。非法帧、超限消息、无效 UTF-8 和读取到一半的超时都会关闭本客户端连接。JSON-RPC 只匹配本次请求 ID，通知和其他请求的响应不会被当成本次结果。

一次 RPC 的写入、读取及业务重试共用一个单调时钟截止时间：

- 普通账户、额度和用量读取最多 10 秒
- 其他请求默认最多 20 秒
- 可重试业务错误最多再试一次，不能重新获得一份超时预算
- 不支持的方法只缓存到当前 session，重连后重新探测
- `AppServerRequestBudget` 通过 TaskLocal 继续约束连接、认证刷新、重试和实际发送；时间回拨不能延长请求
- 取消和超时不会留下仍在等待结果的可复用 socket

连接最多复用一小时，到期后的下一次请求重连自己的 socket。这个上限不控制 daemon 寿命，也不会强制后台采用刚升级的磁盘版本。

## 账户与缓存

| 方法 | 用途 |
| --- | --- |
| `account/read` | 账户、套餐与认证状态 |
| `account/rateLimits/read` | 额度窗口、Reset Credits 数量和可选明细 |
| `account/rateLimitResetCredit/consume` | 使用明确指定的 Reset Credit |
| `account/usage/read` | 后台支持时读取服务端用量 |
| `config/read`、`config/batchWrite` | Codex 配置读取与受控写入 |
| `hooks/list` | 已有 Hook 配置的独立校验入口，不是共享任务采集门槛 |

一次刷新统一控制认证刷新资格，`account/read(refreshToken: true)` 最多执行一次。传输失败时至多重建一次客户端连接；重新连接仍失败则留待下一次正常刷新。

账户有效时，额度和用量允许独立失败：

| 当前结果 | 输出 |
| --- | --- |
| 成功 | 更新缓存，标记为新鲜 |
| 普通失败，同账户有缓存 | 复用缓存，保留 `stale` 标记 |
| 普通失败，无缓存 | 保留缺失状态 |
| 方法明确不支持 | 该来源缺失，不用旧缓存冒充支持 |
| 账户改变 | 先清空旧账户补充缓存 |

缺失不是 `0`。额度通知和自动重置不会用 stale 额度触发操作。`account/usage/read` 的每日 bucket 缺失表示每日数据不可用，空数组才表示已读取但没有记录；合法部分响应不拿旧字段补齐。

默认每分钟刷新，可选 1、2、3、5 或 10 分钟，偏好键保持为 `CodexQuota.refreshIntervalSeconds`。修改间隔重排计时器；手动刷新完成后重新对齐倒计时。`RefreshTaskCoordinator` 校验代次，取消后的旧结果不能提交；需要补刷的动作通过 `refreshAfterCurrent` 等当前刷新收尾。

普通轮询继续受 `SystemConnectionGate` 控制：系统睡眠、合盖且无工作中的外部显示器时暂停；物理外接屏、虚拟屏和镜像屏按系统状态判断。DarkWake 不解除普通采集的显示唤醒门槛。自动重置的显式唤醒计划是另一条独立路径。

## Reset Credits

界面使用“留存重置”或“Banked Resets”，协议仍使用 `rateLimitResetCredits`

- `availableCount` 是权威总数，不能从明细长度反推
- `credits == nil` 表示明细不可用，空数组表示已经读取但没有返回凭证
- 明细可能被截断，只处理实际列出的 opaque `id`
- 自动消费必须同时具备 `status == available`、`resetType == codexRateLimits` 和明确的 `expiresAt`
- 只知道数量、缺少到期时间或响应 stale 时不消费

自动重置默认关闭，提前量可选 15 分钟、30 分钟、1 小时、2 小时、4 小时或 6 小时，默认 30 分钟。开启和 Helper 授权流程见 [防睡眠与 Helper](sleep-prevention.md)

消费前强制重读账户和凭证，再在实际请求发送前校验同一账户及截止时间。每次显式传入：

```text
account/rateLimitResetCredit/consume
  creditId: <exact opaque id>
  idempotencyKey: <deterministic UUIDv5>
```

| 结果 | 处理 |
| --- | --- |
| `reset`、`alreadyRedeemed` | 记录成功，不再消费该凭证，刷新额度并按设置通知 |
| `nothingToReset` | 未消费，进入冷却后复查 |
| `noCredit` | 刷新明细；目标消失则静默停止，仍存在则稍后复查 |

凭证消失不能区分手动使用、其他设备使用或过期，不据此发送成功通知。已确认的成功即使晚于取消到达也必须记住，但旧响应不能重新建立计划。

### 幂等身份

同一 `creditId` 跨设备、跨版本保持相同 UUIDv5，不依赖云同步：

```text
namespace      = c2904ab3-0a87-5648-997d-bd8515edd401
name           = 原始 creditId 的 UTF-8 字节
output         = 小写 UUID
creditId       = RateLimitResetCredit_123
idempotencyKey = 4035685d-9ca4-524f-8193-6e0ae2a7b3b9
```

namespace 来源 URL 只是身份计算约定，不是运行时网络访问。到期时间变化不改变凭证身份。原始 `creditId` 不写入本地持久化状态，下次启动从新鲜响应恢复。

### 尝试预算与唤醒

`AutoResetSchedule` 按凭证保留预算，普通快照刷新、开关变化或重新排定时器不会恢复已经消耗的初始预算：

1. 临期后初始窗口最多 5 分钟，暂时错误按 `15s, 30s, 60s, 120s` 退避
2. 窗口结束或返回 `nothingToReset` 后，按 `min(15 分钟, 提前量 / 3)` 冷却复查
3. 到期前 3 分钟保留最终复查机会，暂时错误最多追加两次，间隔为 15 秒和 30 秒
4. 到期前 1 分钟为安全截止，所有连接和消费预算都不能越过它

普通评估跨过最终复查点时承接该机会，不并行启动第二轮。到期时间延长可以重排最终机会，但不重新获得初始预算。认证失败暂停，明确的协议或参数错误停止当前凭证。

每轮评估单独持有短时空闲睡眠断言，结束时释放。关闭、睡眠、账户切换和退出准备先使旧评估失效；新触发等待旧任务真正收尾，避免旧任务释放新断言或并行消费。

系统唤醒只预约首次执行和最终复查，普通冷却不反复唤醒 Mac。Helper 仅接收固定 owner 的 `wake` 时间，不接触账户或网络；开启自动重置不要求同时开启普通防睡眠。退出准备冻结自动重置，确认 Helper 清除预约和租约后再退出，取消退出时恢复评估。

## 隐私与验证

`RequestLogStorage` 只在内存中保存最近 500 条交互。请求和响应入库前解析 JSON 转义，对代理 URL 认证部分及常见 token、API key、密码、Cookie 字段脱敏。共享活动通知不写入账户交互日志。系统日志只记录控制流分类，不保存账户、凭证 ID、额度或会话正文。

验证重点：

- 真实临时 Unix socket 完成握手、分片、ping/pong、掩码和 ID 匹配
- 非法握手、非法帧、消息超限和半帧超时关闭客户端
- 请求取消、超时和重连不影响共享监听器及其他客户端
- 无磁盘启动器时仍能连接已有后台，连接缺失时才尝试固定启动命令
- 写入、业务重试、认证刷新共用截止，过期凭证和变更账户不能消费
- 缺失字段、同账户缓存、账号切换和 unsupported 方法保持独立语义
- 重复快照不重启预算，取消后不重建计划，成功结果不重复消费

关键实现：[`CodexSharedSocket.swift`](../../CodexBar/Services/CodexStatus/CodexSharedSocket.swift)、[`AppServerSession.swift`](../../CodexBar/Services/CodexStatus/AppServerSession.swift)、[`CodexStatusService.swift`](../../CodexBar/Services/CodexStatus/CodexStatusService.swift)、[`AutoResetController.swift`](../../CodexBar/Services/CodexStatus/AutoResetController.swift)、[`AutoResetSchedule.swift`](../../CodexBar/Services/CodexStatus/AutoResetSchedule.swift)、[`AppServerRequestBudget.swift`](../../CodexBar/Services/CodexStatus/AppServerRequestBudget.swift)

官网日统计和设备日志价值估算继续由用量中心独立管理。远端历史额度不能替代本机当前账户的新鲜凭证，也不能自行触发重置卡消费。
