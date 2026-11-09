# Keytide macOS 发布流程（手动更新）

当前范围为 macOS DMG / ZIP，App 的更新按钮打开 `Xuan-lprk/KeyTide` 的 Releases 页面。`KeyStatsInAppUpdatesEnabled` 与 `SUEnableAutomaticChecks` 均保持 false；不生成 appcast、不读取 Sparkle 私钥、不启用自动更新。本流程使用现有 ad-hoc 签名，不进行 Developer ID 签名或 Apple 公证。

## 本地准备与打包

在真实仓库根目录执行：

```bash
# 示例版本；仅准备文件，不提交、打 tag 或推送。
./scripts/release.sh 1.52.2

# 编译、归档、签名和打包；不启动 App，不安装 Helper，不发布。
./scripts/build_dmg.sh
```

`release.sh` 仅更新主 App Debug / Release 两个配置的 marketing version，并将一致的 build number 加一。它根据主 App 的 Info.plist 路径定位配置，不依赖开发团队 ID；不修改 Helper 或 Windows 版本。重复运行会再次增加 build number，执行后应审查 diff。旧 `publish_release.sh v1.52.2` 仅作为同样的本地准备别名；不再接受旧 output-dir 参数。

Beta 使用 `1.52.2-beta.1` 形式；App 的 marketing version 保持 `1.52.2`，beta 标识留在 Git tag / Release 名称中。每次候选按本地准备流程递增 build number。

产物固定输出到：

- `build/ReleasePackaging/output/Keytide.dmg`
- `build/ReleasePackaging/output/Keytide.zip`
- `build/ReleasePackaging/output/SHA256SUMS`

每次打包使用独立的 `build/ReleasePackaging/run.*` 目录，保留构建日志、归档和中间产物，便于验收。不会清空整个 `build/`；这些文件均被 Git 忽略，可在确认不再需要后手动整理。仓库根目录可能留有旧版 `Keytide.dmg`，新脚本不会更新它，应使用上述输出目录。

DMG 和 ZIP 来自同一份嵌入 vendored Helper 后完成签名的 App，不再各自编译。脚本在生成产物前检查 Helper cdhash 是否与 vendor 记录一致；此检查不证明系统 TCC 权限或升级连续性已经通过。构建失败直接退出，不自动重试另一轮归档；失败时不要将 output 中可能保留的上一轮产物当成本次结果。

同步服务地址可选。未提供时显式传入空的 `KEYSTATS_SYNC_SERVICE_URL`，避免继承开发配置；新安装不会取得构建时同步服务地址。已有同步状态及其行为不在本轮修改范围内。确实准备好自有生产同步服务后，可显式设置合法的 HTTPS workers.dev 地址：

```bash
KEYSTATS_SYNC_SERVICE_URL=https://your-service.workers.dev ./scripts/build_dmg.sh
```

`KEYSTATS_RELEASE_VERSION=X.Y.Z` 可仅覆盖此次打包版本而不改源码；通常应先运行版本准备脚本。打包脚本会拒绝不合法版本、非空但不合法的同步地址，以及已开启 App 内更新的配置，避免静默生成不符合本流程的发布包。

脚本回归测试使用合成的构建／签名／磁盘工具，不启动真实 App：

```bash
python3 -m unittest discover -s scripts/tests -v
```

它验证文件保留、失败退出、Helper 身份检查和本地版本准备边界；实际归档与安装验收仍需单独执行。

## GitHub Actions

`.github/workflows/release.yml` 仅在推送 `vX.Y.Z` 或 `vX.Y.Z-beta.N` tag 后构建并发布到当前仓库。推送 tag 是实际发布动作，必须得到用户明确授权；本地脚本不会替用户执行。

工作流运行脚本契约测试、核心 Swift 测试和 vendored Helper 校验，然后构建 universal macOS DMG / ZIP、生成并校验 SHA256，最后创建当前仓库 Release。Beta 标为 prerelease，不设为 latest。

- 不依赖 Windows 构建，不修改 Windows 发布源码。
- 不生成 Sparkle feed，不要求 `SPARKLE_PRIVATE_KEY`。
- `KEYSTATS_SYNC_PRODUCTION_URL` 仓库变量可留空；非空时传入并校验。
- 不读取 Homebrew / Scoop token，不向上游或其他仓库推送。
- build job 只有 contents read；只有创建 Release 的 job 有 contents write。

## 正式发布前尚需验收

最终 UI 定稿后，使用最终 Release 产物验证首次安装、辅助功能授权与真实采集、退出重开、旧版覆盖升级和历史数据保留；确认实际 Helper 身份与权限连续性。另做菜单两套风格、Mac / 机械 Growth 和 Replay、窗口关闭清理、辅助功能与能耗验收。构建或 cdhash 校验不能替代这些真机检查。

未来启用 Sparkle 更新时，需另行验证公私钥匹配、归档签名、feed 和真实升级，并明确授权开启 App 内更新。Developer ID / 公证也作为独立发布路径处理，本轮不变更签名身份或生成密钥。
