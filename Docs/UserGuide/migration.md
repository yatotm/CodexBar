# 切换到独立 fork

本分支使用 `CodexBar.app`，推荐安装到 `/Applications`。显示名称与上游相同，内部标识独立；需要同时保留两版时，请放在不同目录。正式标识为 `io.github.yatotm.codexbar`，Debug 追加 `.debug`。tag 从 `fork-v1.0.0` 开始独立递增，不跟随上游版本。

## 首次迁移

迁移工具只复制旧数据，不删除旧安装，也不覆盖已经使用过的 fork。此前使用本分支旧 Debug 构建时，执行：

```bash
python3 Scripts/migrate-fork.py --from debug
```

这是预览。确认来源正确后，在旧版关闭 Hook、防睡眠和自动重置，退出所有 CodexBar 实例，再执行：

```bash
python3 Scripts/migrate-fork.py --from debug --apply
```

从上游正式版迁移使用 `--from release`；迁入 fork 的 Debug 版另加 `--to debug`。迁移完成后再首次启动新 App。

## 保留与重新配置

| 项目 | 处理方式 |
| --- | --- |
| 来源、筛选、代理和额度参考 | 复制到新的偏好域，不修改旧设置 |
| 日志聚合、用量数据库和账号缓存 | 从 `~/Library/Application Support/CodexBar` 复制到 `CodexBar-yatotm`，数据库通过一致快照复制 |
| 原始 Codex / Claude 登录与会话 | 保留原位，不修改登录文件 |
| VPS 定时器、数据库和来源身份 | 保持原位，Mac 迁移不改远端部署 |
| HTTPS 专用令牌 | 新钥匙串命名空间不复用旧令牌，需要重新填写 |
| 旧 iCloud 数据 | 功能已移除，不复制或读取旧同步游标，也不删除云端数据 |
| Helper、防睡眠和自动重置 | 不迁移 root 恢复状态；相关开关默认关闭，签名就绪后重新开启并授权 |
| Hook、通知、登录项 | 在新 App 中重新确认，迁移工具不改写其他应用的配置 |

旧数据仍可供旧版本使用。不要同时用两版控制防睡眠或自动重置；旧版退出时会清理自己的唤醒计划，新 Helper 不会接管旧 owner。

## 签名与更新

Developer ID Application 签名和 Apple 公证用于正式分发，需要 Apple Developer Program 会员。费用及申请方式以 [Apple 官方说明](https://developer.apple.com/cn/programs/enroll/) 为准。仓库中的 Sparkle 更新签名是另一套独立机制，不代替 Apple 公证。

ad-hoc 构建可用于本地验证，缺少匹配签名时原 Helper 不可用；iCloud 功能已移除。正式发布采用哪种签名方式，以对应 Release 的说明为准。

首次从上游或旧 Debug 切换必须手动安装。新正式版只检查本仓库的更新，Debug 不接入正式更新通道。

返回 [用户指南](README.md)

## 未公证安装包首次打开

当前 Release 提供通用 DMG，将 `CodexBar.app` 拖入 Applications 后打开即可。若系统阻止首次启动，到 `系统设置 > 隐私与安全性` 选择 `仍要打开` 并确认。无需关闭系统的整体安全保护。操作位置见 [Apple 官方说明](https://support.apple.com/zh-cn/102445)

当前 ad-hoc 构建没有可供 Helper 验证的 Team ID，因此防睡眠和自动重置暂不可用。iCloud 功能已移除。这些限制与是否手动允许启动 App 是两回事。统计、官网分析、SSH/HTTPS 与 Sparkle 更新不依赖这些权限。

## 从旧名称升级

旧安装名为 `CodexBar Fork.app` 时，可通过应用内更新升级，但文件名可能仍保留旧名称；需要改名时，请先退出应用再将文件名改为 `CodexBar.app`。移动到 `/Applications` 前先退出应用，确认目标目录没有需要保留的同名 App；安装完成并核对数据后，删除旧位置的 App。内部标识和数据目录不变，无需重新运行数据迁移工具。已启用的 Hook 和登录项需要核对新路径。
