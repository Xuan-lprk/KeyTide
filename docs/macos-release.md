# Keytide macOS 发布流程（手动更新）

当前范围为 macOS DMG / ZIP，App 的更新按钮打开 `Xuan-lprk/KeyTide` 的 Releases 页面。`KeytideInAppUpdatesEnabled` 与 `SUEnableAutomaticChecks` 均保持 false；不生成 appcast、不读取 Sparkle 私钥、不启用自动更新。本流程使用现有 ad-hoc 签名，不进行 Developer ID 签名或 Apple 公证。

## 本地准备与打包

在真实仓库根目录执行：

```bash
# 示例版本；仅准备文件，不提交、打 tag 或推送。
./scripts/release.sh 1.52.2

# 编译、归档、签名和打包；不启动 App，不安装 Helper，不发布。
./scripts/build_dmg.sh
```

`release.sh` 仅更新主 App Debug / Release 两个配置的 marketing version，并将一致的 build number 加一。它根据主 App 的 Info.plist 路径定位配置，不依赖开发团队 ID；不修改 Helper 版本。重复运行会再次增加 build number，执行后应审查 diff。仓库中不再提供旧 `publish_release.sh` 别名。

Beta 使用 `1.52.2-beta.1` 形式；App 的 marketing version 保持 `1.52.2`，beta 标识留在 Git tag / Release 名称中。每次候选按本地准备流程递增 build number。

产物固定输出到：

- `build/ReleasePackaging/output/Keytide.dmg`
- `build/ReleasePackaging/output/Keytide.zip`
- `build/ReleasePackaging/output/SHA256SUMS`

每次打包在 `build/ReleasePackaging/run.*` 保留构建日志、归档和生成的包。DerivedData 和打包暂存使用本机临时目录，避免文件同步服务给签名包附加 Finder 元数据。验收使用上述输出目录。

Xcode 的 Release 配置在签署主 App 前嵌入 `vendor/KeytideHelper.app`。Xcode Organizer 的归档和本地脚本共用同一嵌入步骤。打包脚本从签名完成的归档生成 DMG 和 ZIP，检查主 App 和 Helper 的 Bundle ID、双架构、签名完整性，以及包内 Helper 与 vendor 的可执行文件逐字节一致。手动更新构建不链接或内嵌 Sparkle，脚本会拒绝带该框架的产物。构建失败直接退出，output 可能保留上一轮产物。

Debug 生成 `Keytide Debug.app`，内嵌当前源码编译的开发 Helper。它使用独立的 Bundle ID、LaunchAgent、偏好域、回放目录和 Keychain 条目。首次验证开发版真实输入时，系统需要单独授予 Keytide Debug Helper 权限。Debug 的 `--debug-gui-acceptance` 只尝试连接已经注册的开发 Helper，适合仅验证 UI。

生产 Helper 的二进制固定在 vendor 中。需要交付生产 Helper 代码变更时，通过 `scripts/rebuild_vendored_helper.sh` 明确更新固定的二进制和 cdhash，并验证新签名的系统授权和覆盖升级。日常主 App 更新沿用现有生产 Helper，保留正式版的 Bundle ID、安装路径和数据域。macOS 实际授权状态仍以真机验收为准。

`KEYSTATS_RELEASE_VERSION=X.Y.Z` 可仅覆盖此次打包版本而不改源码；该环境变量名称为现有脚本接口。通常应先明确版本号，再运行版本准备脚本。仅验收当前版本时直接运行打包脚本，不自动递增版本或 build number。脚本会拒绝不合法版本及已开启 App 内更新的配置。

当前产品与打包脚本不提供同步服务配置；不需要 Sync URL、服务端或插件。

脚本回归测试使用合成的构建／签名／磁盘工具，不启动真实 App：

```bash
python3 -m unittest discover -s scripts/tests -v
```

它验证文件保留、失败退出、Helper 身份检查和本地版本准备边界；实际归档与安装验收仍需单独执行。

## GitHub Actions

`.github/workflows/release.yml` 仅在推送 `vX.Y.Z` 或 `vX.Y.Z-beta.N` tag 后构建并发布到当前仓库。推送 tag 是实际发布动作，必须得到用户明确授权；本地脚本不会替用户执行。

工作流运行脚本契约测试、核心 Swift 测试和 vendored Helper 校验，然后构建 universal macOS DMG / ZIP、生成并校验 SHA256，最后创建当前仓库 Release。Beta 标为 prerelease，不设为 latest。

- 只构建 macOS App，不依赖其他平台。
- 不生成 Sparkle feed，不要求 `SPARKLE_PRIVATE_KEY`。
- 不读取 Homebrew / Scoop token，不向上游或其他仓库推送。
- build job 只有 contents read；只有创建 Release 的 job 有 contents write。

## 正式发布前尚需验收

最终 UI 定稿后，使用最终 Release 产物验证首次安装、辅助功能授权与真实采集、退出重开、旧版覆盖升级和历史数据保留；确认实际 Helper 身份与权限连续性。另做菜单两套风格、Mac / 机械 Growth 和 Replay、窗口关闭清理、辅助功能与能耗验收。构建或 cdhash 校验不能替代这些真机检查。

未来启用 Sparkle 更新时，应在单独的发布配置中恢复依赖、定义 `KEYTIDE_SPARKLE`，验证主应用与框架的签名兼容、公私钥匹配、feed 和真实升级，并明确授权开启 App 内更新。Developer ID / 公证也作为独立发布路径处理。

## 本地安装包验收

1. 以本次脚本成功结束和对应 run 目录为准，校验 `SHA256SUMS`；不要拿失败运行前的旧 output 产物当作新包。
2. 只读挂载 DMG，检查 `Keytide.app` 与 Applications 快捷方式；解压 ZIP，比较两种包内 App 文件内容、符号链接及签名是否一致。
3. 主 App／Helper 标识应分别为 `com.xuanlprk.KeyTide`／`com.xuanlprk.KeyTide.helper`。两者二进制应含 arm64 与 x86_64；包内 Helper cdhash 应与 vendor 一致。
4. 检查 App 图标、版本号、最低 macOS 版本，以及手动更新配置。执行代码签名完整性检查，并单独记录 Gatekeeper 分发评估；ad-hoc 签名不等于 Developer ID、公证或可信分发。
5. 退出已有主 App 后，从包内复制到 Applications，实际检查启动、菜单、图标、权限提示和“检查更新”目的地址。系统权限由用户手动授予；不为验收关闭 Gatekeeper、执行 TCC reset 或批量移除下载隔离标记。

安装包验收与旧版升级验收分开：首次授权通过不能证明历史数据迁移或升级后的权限连续性。记录无法完成的真机步骤，不用静态包检查代替。
