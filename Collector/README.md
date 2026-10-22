# 远程采集与实时监听

日志统计仍每 5 分钟采集一次，Mac 通过 SSH 读取结果。Codex 实时任务由独立的小型监听器接入该机器自己的共享后台服务；Claude 继续使用本地日志和 Hook。两条链路可以同时运行，不需要公开端口或部署 Docker。

| 链路 | 负责内容 | 运行方式 |
| --- | --- | --- |
| 日志采集 | Token、模型、热力图、额度历史和价值估算 | 定时启动，完成后退出 |
| 共享服务监听 | Codex 任务阶段、子 Agent、审批和计划进度 | 本机持续监听，SSH 转发去正文的快照 |

Mac 合盖或断网不影响远端记录。恢复连接后读取最新状态，历史用量继续从日志补齐。Docker/HTTPS 保留为多客户端访问历史统计时的可选方式。

## 安装定时任务

目标机器需要 systemd 和 `/usr/bin/python3`，Python 最低版本为 `3.9`。从仓库根目录执行安装器，`--user` 指定日志拥有者；安装系统单元需要 root 权限。

```bash
sudo python3 Collector/install-timer.py --user your-user --providers codex,claude
```

只采集 Codex 时使用 `--providers codex`。可以通过 `--codex-home`、`--claude-home`、`--state-dir` 指定实际目录；使用自定义 `XDG_STATE_HOME` 时必须显式传入现有 `--state-dir`，避免创建另一份统计库。

安装器会打印 `stateDirectory`。把它填入 Mac 对应 SSH 来源的 `远端统计缓存目录`，之后 Mac 只导出该数据库，不再触发远端日志扫描。

安装内容包括：

- 日志用户主目录下的 `.local/share/codexbar-usage/collector.py` 和安装记录
- `/etc/systemd/system/codexbar-usage.service` 与 `/etc/systemd/system/codexbar-usage.timer`
- 原有统计数据库继续使用，文件位置、统计标识和 Mac 游标不需要重置

任务按五分钟日历周期运行，允许系统在 30 秒内合并唤醒；开机后补一次错过的触发。同一服务不会重叠执行，单次运行最长 75 秒。任务禁止联网，文件系统默认只读，只放开自己的数据目录和 Claude 事件缓存目录；标准输出丢弃，避免把统计明细写进 journal。

查看状态和手动执行：

```bash
systemctl list-timers --all codexbar-usage.timer
systemctl status codexbar-usage.service
sudo systemctl start codexbar-usage.service
journalctl -u codexbar-usage.service -n 20
```

正常执行结束后服务显示 `inactive`，定时器仍为 `active`。这表示采集进程已经退出，不是故障。

停止或移除定时任务：

```bash
sudo systemctl disable --now codexbar-usage.timer
sudo python3 Collector/install-timer.py --uninstall
```

移除任务会停止采集并删除本程序的系统单元，保留采集脚本和统计数据库。重新运行安装命令可以恢复；安装器拒绝覆盖不属于本程序的同名单元，也不会自动切换已安装任务的数据目录。

## Codex 共享服务监听

要求该机器正在运行的 Codex 共享服务为 `0.162.0` 或更新版本。监听器连接本机 Unix socket，只观察已加载会话，不启动模型任务、不回答审批，也不管理官方后台服务的退出。仅升级 CLI 安装文件，不能代替运行中服务的版本检查。

在 Mac 的来源设置中启用实时任务，会安装对应机器的监听器。手动安装时，以 Codex 日志拥有者身份从仓库根目录执行：

```bash
python3 CodexBar/Resources/SharedCodexCollector.py install
```

自定义 Codex 目录使用 `--codex-home`，与原日志来源保持一致。安装器保留现有配置，不会自动更换已安装实例的数据目录。Linux 的 root 用户使用系统服务，普通用户使用用户服务；macOS 使用当前图形登录用户的 LaunchAgent，不修改系统睡眠设置。

| 项目 | 位置或名称 |
| --- | --- |
| 监听脚本与安装记录 | `~/.local/share/codexbar-shared-codex/` |
| 独立状态库 | `~/.local/state/codexbar-shared-codex/shared-activity-v1.sqlite` |
| Linux 服务 | `codexbar-shared-codex.service` |
| macOS LaunchAgent | `io.github.yatotm.codexbar.shared-codex` |

任务主要通过服务端推送更新。定时核对用于补漏，空闲会话不会每 5 秒重新读取；没有变化时不重复写入任务快照。断开时活跃任务显示为状态待确认，不伪造完成，重连恢复的旧终态不重复通知。

Token 和价值估算继续使用原日志数据库。新状态库仅额外保留去重的审批、中断元数据，原日志采集器按相同 Codex 目录只读导入，最长保留 210 天；不重复计入 Token、工具和轮次。会话标识沿用原哈希算法，不增加虚假的会话数。

确认新监听器正常后，下面的命令可撤除本项目旧的 Codex 实时 Hook；只有新服务健康才会执行，其他程序的 Hook、Claude 配置、原日志和统计数据库均保留：

```bash
python3 CodexBar/Resources/SharedCodexCollector.py install --retire-legacy-hooks
```

查看快照或移除监听器：

```bash
python3 CodexBar/Resources/SharedCodexCollector.py snapshot
python3 CodexBar/Resources/SharedCodexCollector.py uninstall
```

移除只停止 CodexBar 自己的 Python 监听服务，保留数据库，官方 Codex 后台服务和正在执行的任务不受影响。

## 可选的 HTTP 服务

HTTP 统计端同样以 Python 标准库和 SQLite 实现，默认每 5 分钟扫描增量。HTTP 只开放 `/v1/changes` 与 `/healthz`，全部需要专用 Bearer 令牌。没有远程命令、任意路径读取、登录或推理接口。选择这种模式时不要同时对同一数据库启用定时采集任务。

## Docker 部署

从仓库根目录开始，在目标机器准备以下目录。使用与日志拥有者相同的 UID/GID 运行统计端，避免修改原始日志权限。

```bash
mkdir -p /srv/codexbar/data /srv/codexbar/empty
umask 077
openssl rand -hex 32 > /srv/codexbar/collector.token
cp Collector/.env.example Collector/.env
```

编辑 `Collector/.env`，填写真实的 UID/GID、数据目录和日志目录。`PROVIDERS=codex,claude` 才启用 Claude；只统计 Codex 时，把 `CLAUDE_PROJECTS` 和 `CLAUDE_SIGNALS` 指向准备好的空目录。没有归档目录时，也可以把 `CODEX_ARCHIVED` 指向空目录。

所有挂载源必须预先存在。Claude 被动接入在宿主机执行，`CLAUDE_SIGNALS` 指向其生成的 `~/.claude/codexbar-usage/signals`。容器只读取这些日志子目录，不要挂载整个用户主目录、Codex 认证文件或 Claude 凭据目录。

```bash
docker compose --env-file Collector/.env -f Collector/compose.yaml up -d --build collector
```

默认只把服务映射到宿主机 `127.0.0.1:8765`。容器根文件系统只读，移除 Linux capabilities，限制进程数量、内存和 CPU。SQLite 与令牌文件必须能被所选 UID 读取，数据库目录还需要写权限。

## 通过 SSH 读取

在 Mac 的来源设置中选择 SSH，填写主机别名，并把 `远端统计缓存目录` 设置为宿主机的 `COLLECTOR_DATA`。这种方式不需要发布端口；SSH 只调用采集器的固定只读导出命令。

## 通过 HTTPS 读取

将 `USAGE_DOMAIN` 设置为你控制的域名，确认 DNS 指向统计机，且相应端口可供证书验证和 HTTPS 使用，然后启动可选的 Caddy 服务：

```bash
docker compose --env-file Collector/.env -f Collector/compose.yaml --profile https up -d
```

在 Mac 添加 HTTPS 来源，根地址填写 `https://你的域名`，专用令牌填写 `collector.token` 的内容。令牌不放在 URL、Git 或请求日志中；修改令牌文件后重启统计端，再更新 Mac 钥匙串中的令牌。

如果已经有 HTTPS 网关，也可以只部署 collector，让现有网关反向代理到本机回环端口。不要绕过客户端证书校验。

## 直接运行

从仓库根目录运行以下命令：

```bash
python3 Collector/server.py \
  --state-dir /srv/codexbar/data \
  --codex-home ~/.codex \
  --claude-home ~/.claude \
  --providers codex,claude \
  --token-file /srv/codexbar/collector.token
```

这会监听回环地址。需要容器内监听其他地址时使用 `--listen`，TLS 交给网关处理。

## 协议与维护

客户端携带 `epoch` 和 `cursor` 请求增量，单页最多 3000 条经过筛选的记录。数据库更换时 `epoch` 改变，客户端按新来源重新回填。每台机器的来源贡献分开保存，合并时再按请求哈希去重。

暂停或卸载服务不会删除源日志。升级前备份自己的统计数据库；不要在不同 schema 的程序之间直接复用数据库。当前协议和数据库格式均为 `1`，未来格式变化需要先制定明确的兼容方案。

测试入口：

```bash
python3 -m unittest discover -s Tests -p 'test_usage_*.py' -v
python3 -m unittest discover -s Tests -p 'test_shared_codex_collector.py' -v
```

## 周限历史补充

新版采集器在普通增量采集的剩余预算内更新独立 `quota-history-v1.sqlite`，包含时间、周限比例、套餐类型和可用的账号摘要。定时任务仍不读取凭据、不访问网络，原 `usage-v1.sqlite` 与导出协议保持不变。历史缓存故障不会使原统计任务失败。

Mac 可通过 SSH 的 `quota-history --skip-scan` 只读获取缓存。账号归属由 Mac 的历史来源选择确认，显式账号标识会另行过滤；OAuth/API 识别不依赖自定义 profile 名称。缺少缓存或缓存过旧时可有界补扫。该历史协议暂不通过 HTTPS 服务提供。
