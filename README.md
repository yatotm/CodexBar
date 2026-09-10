<div align="center">

<img src="Images/icon.png" width="128" alt="CodexBar">

# CodexBar

**在 macOS 菜单栏查看 Codex 与 Claude Code 用量**

简体中文 | [English](README.en.md)

[![macOS](https://img.shields.io/badge/macOS-15.0+-000000?logo=apple&logoColor=white)](https://www.apple.com/macos/)
[![Release](https://img.shields.io/github/v/release/yatotm/CodexBar?color=1F6FEB)](https://github.com/yatotm/CodexBar/releases)
[![Downloads](https://img.shields.io/github/downloads/yatotm/CodexBar/total?color=2EA043)](https://github.com/yatotm/CodexBar/releases)
[![License](https://img.shields.io/github/license/yatotm/CodexBar?color=8957E5)](LICENSE)

[功能](#功能) | [安装](#安装) | [快速开始](#快速开始) | [使用文档](#使用文档) | [隐私](#隐私) | [运行架构](Docs/DeveloperGuide/architecture.md)

<img src="Images/preview-zh.gif" width="640" alt="CodexBar 预览">

</div>

---

CodexBar 是面向 macOS 15 及更高版本的菜单栏 App，集中展示 Codex 额度、任务状态，以及本机和远程设备的 Codex、Claude Code 用量。

> 本仓库基于 [bob-zebedy/CodexBar](https://github.com/bob-zebedy/CodexBar) 独立维护。保留原菜单栏交互，增加多机器统计、Claude 被动额度和订阅价值估算；下载、更新与反馈均使用本仓库。

## 功能

### 账户与额度一目了然

- 展示当前 Codex 账户和套餐
- 展示全部额度窗口、剩余比例和重置时间
- 展示可用积分和留存重置
- 支持自动重置，可设置在留存重置过期前 15 分钟到 6 小时执行，默认提前 30 分钟；计划到点时可唤醒 Mac，并在执行前重新确认可用状态
- 可在菜单栏图标旁直接显示所选额度窗口

### 看见自己的 Codex 使用节奏

- 展示累计 Token、单日峰值和连续使用天数
- 展示最长任务时长
- 通过 30 周热力图回顾每日 Token 用量
- 开启 CodexBar Hook 后可查看会话、对话轮次、工具调用和子 Agent 等每日统计

### 汇总多台设备的用量

- 在 `全部 / Codex / Claude` 标签间切换，设备明细默认折叠
- 汇总 Mac 与 SSH 开发机，按机器、模型、登录方式和时间查看，跨设备去重
- 用量中心提供每日图表、输入输出与缓存分布；VPS 可每五分钟独立采集，也可部署 Docker/HTTPS 统计端
- Claude 额度取同账号最新的本地缓存，可选接入状态栏和 Hook 补充后续记录

### 了解订阅额度的使用价值

- 通过本机 Codex OAuth 读取官网账号分析，无需浏览器 Cookie
- 合并同账号设备的周限观察，按实际重置周期估算价值，支持提前重置和套餐变化
- 有数据时按模型价格推算，缺少样本时显示所选套餐参考范围，并区分估算依据

### 不错过正在发生的任务

- 菜单栏状态点区分运行中、等待批准和刚完成任务
- 主面板展示当前任务、项目、模型、推理强度和持续时间
- 任务中心集中查看并发任务、最近完成和最近终止记录
- 支持任务完成、等待批准和异常会话提醒

### 让长任务安心运行

- 只在符合条件的 Codex 任务存在时防止系统睡眠
- 可选择等待批准期间继续保持，或同时保持屏幕常亮
- 支持最长防睡眠时间、低电量保护和异常会话保护
- 任务结束或保护条件触发后自动恢复系统睡眠

### 融入 macOS 工作流

- 作为菜单栏 App 运行，不占用 Dock
- 支持全局快捷键、开机启动和自动更新
- 原主面板支持中英文，新增用量中心以中文为主
- 支持为 Codex 服务配置 HTTP/HTTPS 代理
- 系统睡眠时暂停 Mac 的周期刷新，正式唤醒后恢复；VPS 采集独立运行

## 安装

### 下载

从本仓库的 [GitHub Releases](https://github.com/yatotm/CodexBar/releases/latest) 下载应用，解压后拖入 Applications。安装包名为 `CodexBar.app`。首次切换请手动安装并按 [迁移说明](Docs/UserGuide/migration.md) 复制旧数据，之后由本分支独立更新。

> 当前 Release 是未公证的通用构建，无需自行编译。首次打开若被系统阻止，请在 `系统设置 > 隐私与安全性` 中选择 `仍要打开`。菜单栏、用量中心和 SSH/HTTPS 统计可用；Helper、防睡眠和自动重置暂不可用；iCloud 功能已移除。

### 从源码构建

```bash
git clone https://github.com/yatotm/CodexBar.git
cd CodexBar
bash Scripts/build-local.sh
```

构建与发布配置见 [开发者指南](Docs/DeveloperGuide/releasing.md)。

## 运行要求

- macOS 15.0 或更高版本
- 已安装并登录 [Codex CLI](https://github.com/openai/codex) 或安装了内置 Codex 的 ChatGPT App 或 Codex App
- 当前运行的 Codex 版本需要为 `0.143.0` 或更高版本
- 使用实时任务等 Hook 功能时，当前运行的 Codex 版本需要为 `0.145.0` 或更高版本
- 采集本机或远程日志需要 Python 3.9 或更高版本，无需额外 Python 包
- Claude 统计需要可读取的会话日志；5h/7d 额度取决于客户端是否留下相应记录

## 快速开始

1. 启动 CodexBar，在菜单栏找到 CodexBar 图标
2. 左键点击图标，在 `全部 / Codex / Claude` 中查看额度与热力图
3. 右键或按住 Control 点击图标打开设置、日志或退出菜单
4. 点击 `用量详情` 添加 SSH 来源；在订阅价值卡片中选择已确认同账号的历史周限来源
5. 需要实时任务时，在 `设置 > 高级` 中启用 CodexBar Hook

默认全局快捷键为 `⌘⇧W`，可在设置中重新录制或关闭。

## 使用文档

| 文档 | 内容 |
| --- | --- |
| [用户指南](Docs/UserGuide/README.md) | 安装、主面板、Hook、通知、防睡眠、同步、全部设置和问题排查 |
| [开发者指南](Docs/DeveloperGuide/README.md) | 架构、数据链路、核心状态机、存储、隐私边界和开发验证 |
| [多机器用量中心](Docs/UserGuide/usage-center.md) | SSH、Claude 被动额度、价值估算与统计边界 |
| [Linux 采集端](Collector/README.md) | 定时任务、Docker 与 HTTPS 部署 |
| [文档导航](Docs/README.md) | 用户与开发文档总目录 |

## 隐私

会话日志在各设备解析，只同步经过筛选的统计元数据，不传输对话正文、工具参数或登录 Token。Claude 采集器不主动请求 Anthropic；Codex 账户额度和官网分析使用本机登录访问官方服务。

本 fork 已移除 iCloud，同步使用所配置的 SSH/HTTPS 来源，更新检查使用独立 Sparkle 更新源。Token、额度比例和美元估算是不同口径，普通网页 Chat 对话不计入这些统计。

完整的数据访问、本机存储和网络边界见 [数据、同步与隐私](Docs/UserGuide/sync-data-privacy.md)

## 反馈

Bug、功能建议或使用问题欢迎通过 [GitHub Issues](https://github.com/yatotm/CodexBar/issues) 反馈。

## 许可证

[GNU General Public License v3.0](LICENSE)
