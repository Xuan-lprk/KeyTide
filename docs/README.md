# Keytide 技术文档

本目录保存深入技术资料、设计和历史实施记录。当前源码与 [`AGENTS.md`](../AGENTS.md) 优先于历史文档；`PROJECT.md` 是本地忽略的交接记录，不随仓库分发；标记为 Historical 或 Superseded 的内容可能包含旧 identifier、旧路径和已经删除的架构，不应直接作为当前操作指令。

## 状态说明

- **Current**：当前仍可作为实现或运维参考。
- **Implemented**：方案已落地，文档主要用于解释设计背景。
- **Deferred**：代码或设计仍保留，但当前不是开发重点。
- **Historical**：历史记录；使用前必须核对当前源码。
- **Superseded**：已被后续实现替代，不应按原步骤执行。

## 当前入口

- [Keytide 产品与构建说明](../README.md)：当前功能、工程命名与兼容边界。
- [Keytide 菜单与窗口 UI 风格](menu-ui-styles.md)：Input Pulse／极客菜单，以及共享风格设置的 Keyboard Studio。
- [Keytide macOS 发布流程](macos-release.md)：版本准备、DMG／ZIP、手动 Releases 更新与发布验收。
- [Keytide 图标资源](../Design/Keytide-Icon-v1/README.md)：用户保存的 Icon Composer 源文件、单色菜单栏模板与历史素材。
- [AI Agent 开发指南](../AGENTS.md)：架构、隐私、构建与操作边界。
- [原生 Helper 独立包](../KeyStatsHelper/README.md)：直接复用正式源码，保持既有权限与 XPC 身份。
- [c3502 原生键鼠插件](../Integrations/c3502-plugin-keystats/README.md)：已完成本机真实键鼠聚合验证，不替换正式 Helper。
- [同步协议 v1](../contracts/sync/v1/README.md) 与 [Sync Worker](../services/sync-worker/README.md)：已有实现，当前不扩展。

用户已确认当前新功能测试通过；最近自动验证为 234 项核心 XCTest、7 项发布脚本测试和 Debug 构建通过。完整 VoiceOver 朗读、性能／能耗、最终分发包与升级验收不因此视为完成。

## macOS 架构与历史审查

当前主项目的输入链路仍为 Helper / listen-only EventTap → XPC → RemoteEventProcessor → StatsManager；没有恢复主 App InputMonitor。正式键盘显示链路为 StatsManager display history → cumulative snapshot → PhysicalKeyMapping → KeyboardUsageProgress → Mac / 机械 3D renderer（保留 2.5D 实现）。两条链路不以 prototype 的 plist reader 相连。

正式 3D 的入口为 `GrowthKeyboardViewController`，数据适配为 `GrowthKeyboardPresentation`，回放为 `GrowthPlaybackDriver`，场景为 `GrowthKeyboard3DScene` / `MechanicalKeyboardScene`，缓存为 `GrowthKeyboard3DRenderer`。布局、字形和 Palette 来自 `EditorialKeyboardRenderer.sceneLayout`，没有正式源码对 Prototypes 的反向依赖。具体文件职责和验收边界见 AGENTS 与根 README，不把多个历史实验说明当成主项目实现状态。

- [macOS KPS/CPS 实现审查](reviews/2026-04-06-macos-kps-cps-review.md) — **Historical / Superseded**：基于旧 `InputMonitor` 架构，结论需对照当前 Helper/XPC/`StatsManager` 复核。
- [左右修饰键 Heatmap 计划](superpowers/plans/2026-04-07-left-right-modifier-heatmap.md) — **Implemented / Historical**：当前实现已保留左右修饰键和旧数据兼容。

## Helper / XPC / Release

- [c3502 原生键鼠插件](../Integrations/c3502-plugin-keystats/README.md) — **Local integration**：复用采集源码、独立权限与子进程，向本机 c3502 客户端发送聚合总量；不替换正式 Helper。

- [macOS 手动更新发布流程](macos-release.md) — **Current**：本地版本准备、DMG / ZIP、当前仓库 CI 与发布验收边界。

- [Accessibility Helper Split 设计](superpowers/specs/2026-04-20-accessibility-helper-split-design.md) — **Implemented / Historical**：解释 Helper 拆分动机；identifier 和签名描述属于 upstream 历史状态。
- [Accessibility Helper Split 实施计划](superpowers/plans/2026-04-20-accessibility-helper-split.md) — **Implemented / Historical**：步骤、路径和中间架构不代表当前源码。
- [Helper Xcode 配置说明](superpowers/plans/2026-04-22-helper-xcode-setup.md) — **Superseded / Historical**：保留 synchronized group 和 target 配置背景；旧 identifier 与 ad-hoc Debug 签名说明已失效。
- [Helper 首发发布说明模板](superpowers/plans/2026-04-24-helper-release-notes-template.md) — **Historical**：仅供首次引入 Helper 的发布记录参考。
- [Vendored Helper 实施计划](superpowers/plans/2026-04-28-vendored-helper.md) — **Implemented / Release reference**：当前 release tooling 仍使用 vendored Helper；以文档顶部 implementation note 和 `scripts/` 实现为准。

当前发布路径使用 ad-hoc 签名与手动 Releases 更新；正式发布前仍需验证最终产物、vendored Helper 身份及 TCC 升级连续性。Developer ID / notarization、Sparkle feed 属于后续另行启用并验收的路径；不要把历史发布计划当作已完成的 Keytide 发布流程。

## Windows

- [Windows i18n 设计](superpowers/specs/2026-04-29-windows-i18n-design.md) — **Implemented / Historical**。
- [Windows i18n 实施计划](superpowers/plans/2026-04-29-windows-i18n.md) — **Implemented / Historical**。
- [Windows 项目说明](../KeyStats.Windows/README.md) — **Current / Deferred**。

## E2EE Sync

- [E2EE Sync 设计](superpowers/specs/2026-07-13-e2ee-sync-design.md) — **Implemented / Deferred**：本地实现存在，真实 staging/production 验证仍是发布门槛。
- [E2EE Sync 实施计划](superpowers/plans/2026-07-13-e2ee-sync.md) — **Implemented / Deferred**：记录跨 macOS、Windows、Worker 和契约的交付状态。

## 历史文档维护规则

- 不为匹配当前代码而重写历史方案中的旧 identifier、旧文件名或实验步骤。
- 发现历史文档与当前实现不一致时，优先更新本索引的状态说明，而不是抹去演进记录。
- 新增长期有效的技术文档时，在本索引登记用途和状态，避免与 README、PROJECT 或 AGENTS 重复。
- 测试、构建和 GUI 验收证据保存在本地忽略的 `build/`，详细交接可另记本地 `PROJECT.md`。本地日志与生成图不进入源码提交。
