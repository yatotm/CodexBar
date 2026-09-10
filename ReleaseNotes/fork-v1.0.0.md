本分支首次独立发布，整合上游的面板内存、侧边窗口恢复与 Helper 状态展示改进。

- 菜单栏增加全部、Codex、Claude 标签和跨设备热力图
- 用量中心支持 Mac、SSH 开发机及可选 Docker/HTTPS 统计端
- 读取 Claude 已有额度缓存，按最新记录展示
- 使用官方 Codex 分析及同账号周限历史估算订阅价值，支持提前重置与套餐变化
- 优化查询、图表和展开交互，系统睡眠期间暂停周期刷新
- App、Helper、本机数据与更新通道使用独立标识，提供保留旧数据的迁移工具
- 下载、反馈和 Sparkle 更新均指向本仓库，tag 使用独立的 fork-v 前缀

统计仅覆盖可获取的数据，美元结果为估算。首次从上游或开发构建切换时，请手动安装此版本。

## 安装

本版提供 Intel / Apple 芯片通用 DMG，无需自行编译。

1. 下载 `CodexBar-fork-v1.0.0.dmg`，打开后将 `CodexBar Fork.app` 拖入 Applications
2. 从 Applications 打开 App
3. 本版未经过 Apple 公证，如系统阻止打开，进入 `系统设置 > 隐私与安全性`，按提示选择 `仍要打开`

本版采用 ad-hoc 应用签名，更新包另有独立 Sparkle 签名。菜单栏、Codex/Claude 统计、多机器同步和用量中心可用；Helper、防睡眠、自动重置及 iCloud 同步不可用，相关入口不会要求重复授权。SSH/HTTPS 统计不受此限制。

从之前的开发构建切换，请先参考 [迁移说明](https://github.com/yatotm/CodexBar/blob/main/Docs/UserGuide/migration.md)。首次打开的系统操作见 [Apple 官方说明](https://support.apple.com/zh-cn/102445)
