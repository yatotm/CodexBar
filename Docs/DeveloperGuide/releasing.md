# 构建与独立发布

本 fork 的下载、更新和问题反馈均位于 [yatotm/CodexBar](https://github.com/yatotm/CodexBar)。保留上游署名及作为技术参考的文档链接。

## 本地验证

```bash
swiftformat --lint .
swiftlint --strict
bash Scripts/verify-usage-center.sh
python3 -B -m unittest discover -s Tests -p 'test_release.py' -v
python3 -B -m unittest discover -s Tests -p 'test_fork_migration.py' -v
bash Scripts/build-local.sh
```

`build-local.sh` 默认生成 Debug 应用，产物放在 `~/Library/Caches/CodexBar/LocalBuild`。Xcode 26.3 无法直接读取上游工程的格式标记，脚本只调整临时副本，保留仓库工程。使用 `CODEXBAR_BUILD_CONFIGURATION=Release` 构建正式配置，`CODEXBAR_LOCAL_OUTPUT` 可指定产物目录。

本地脚本使用 ad-hoc 签名，工程不再包含 CloudKit 权限。它适合验证和无需 Apple 凭据的构建，不等同于 Developer ID 签名或公证。Debug 应用不接入正式更新通道。

## 发布流程

普通修改照常提交、构建和测试，同一待发版本可以积累多个修复。推送代码、修改版本号或推送 tag 都不会自动发布。

1. 准备 `Config/Version.xcconfig` 和对应的 `ReleaseNotes/fork-vX.Y.Z.md`，完成本地验证
2. 向用户说明本次内容，取得针对本次创建 tag 和 Release 的明确同意
3. 在 Actions 手动运行 `Release`，选择 `main` 并勾选本次发布确认

确认后，工作流自动检查格式、运行回归检查、构建、打包和验签，然后创建附注 tag 与 GitHub Release，上传 DMG、ZIP、`appcast.xml` 和 `SHA256SUMS.txt`。本地候选包不代表已发布，历史授权不能用于下一次发布。

云端使用 macOS 26 和 Xcode 26.3，应用最低要求仍为 macOS 15。同一 tag 不移动，已公开附件不覆盖；失败后重试也必须核对本次授权范围。

## 更新信任

- `Info.plist` 中的更新源指向本仓库最新 Release 的 `appcast.xml`
- `SUPublicEDKey` 是本 fork 的 Sparkle 公钥，私钥由 Actions secret `SPARKLE_PRIVATE_KEY` 提供
- 初始私钥保存在维护者本机钥匙串的 `yatotm.CodexBar` 账户中，应另外妥善备份，不能提交到 Git
- Sparkle 更新签名与 Apple 应用签名用途不同，前者不代替公证
- 首次从上游或 Debug 构建切换请手动安装，后续更新走本 fork 的通道

更换更新公钥、应用标识或 Helper 标识会影响已有安装，需要单独设计迁移。自动重置代码中的上游 URL 是 UUID 命名空间，不会发起网络请求，不能作为更新地址替换。

## 应用身份与版本

正式 App 标识为 `io.github.yatotm.codexbar`，Debug 追加 `.debug`，Helper 再追加 `.helper`。安装包分别为 `CodexBar.app` 和 `CodexBar Debug.app`，内部身份与上游分离；显示名称相同，需要共存时使用不同安装目录。

fork 从 `1.0.0` 独立计版本，tag 使用 `fork-vX.Y.Z`，不跟随上游版本或标签。同步上游使用 `git fetch --no-tags`，审核后合并代码；不要导入上游 appcast 或发布附件。

CloudKit 及其容器配置已从工程移除。仓库不再包含原作者的团队、证书或 provisioning profile。正式签名需提供自己的 Team ID、Developer ID Application 证书和公证凭据；具体费用与申请条件见 [Apple Developer Program](https://developer.apple.com/cn/programs/enroll/)

旧安装迁移步骤见 [切换到独立 fork](../UserGuide/migration.md)。迁移不更改 schema，也不修改原安装的数据。

当前发布工作流使用 ad-hoc 签名并生成未公证 DMG，安装步骤和功能限制写入对应 ReleaseNotes。不能把 Sparkle 验签通过表述为 Apple 公证通过。未来改用正式 Apple 签名时保留现有 fork 标识与 Sparkle 公钥。

发布包同时包含 `arm64` 与 `x86_64`。M 芯片运行原生 ARM 代码，Release 保持 Swift `-O` 优化；打包时检查架构，防止误发单架构产物。
