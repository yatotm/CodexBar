# 构建与独立发布

本 fork 的下载、更新和问题反馈均位于 [yatotm/CodexBar](https://github.com/yatotm/CodexBar)。保留上游署名及作为技术参考的文档链接。

## 本地验证

```bash
swiftformat --lint .
swiftlint --strict
bash Scripts/verify-usage-center.sh
python3 -B -m unittest discover -s Tests -p 'test_release.py' -v
bash Scripts/build-local.sh
```

`build-local.sh` 默认生成 Debug 应用，产物放在 `~/Library/Caches/CodexBar/LocalBuild`。Xcode 26.3 无法直接读取上游工程的格式标记，脚本只调整临时副本，保留仓库工程。使用 `CODEXBAR_BUILD_CONFIGURATION=Release` 构建正式配置，`CODEXBAR_LOCAL_OUTPUT` 可指定产物目录。

本地脚本使用 ad-hoc 签名，不申请 CloudKit 权限。它适合验证和无需 Apple 凭据的构建，不等同于 Developer ID 签名或公证。Debug 应用不接入正式更新通道。

## 发布流程

1. 修改 `Config/Version.xcconfig`，同时递增用户版本和构建号
2. 添加对应的 `ReleaseNotes/vX.Y.Z.md`
3. 将通过验证的提交推送到本仓库 `main`

`Release` 工作流会检查格式、运行回归检查、构建 Release、打包 ZIP 和 DMG，并用独立 Sparkle 密钥签名及验签。全部成功后，在同一任务中创建附注 tag 和 GitHub Release，上传安装包、`appcast.xml` 与 `SHA256SUMS.txt`。GitHub 默认令牌创建的 tag 不会触发另一条发布工作流，因此不依赖 tag 的二次触发。

也可在 Actions 手动运行 `Release`。同一 tag 不移动，已公开附件不覆盖；构建失败可修复后重试，已公开版本的修复必须递增版本。不要手工发布同名空 Release。

## 更新信任

- `Info.plist` 中的更新源指向本仓库最新 Release 的 `appcast.xml`
- `SUPublicEDKey` 是本 fork 的 Sparkle 公钥，私钥由 Actions secret `SPARKLE_PRIVATE_KEY` 提供
- 初始私钥保存在维护者本机钥匙串的 `yatotm.CodexBar` 账户中，应另外妥善备份，不能提交到 Git
- Sparkle 更新签名与 Apple 应用签名用途不同，前者不代替公证
- 首次从上游或 Debug 构建切换请手动安装，后续更新走本 fork 的通道

更换更新公钥、应用标识、CloudKit 容器或 Helper 标识会影响已有安装，需要单独设计迁移。自动重置代码中的上游 URL 是 UUID 命名空间，不会发起网络请求，不能作为更新地址替换。
