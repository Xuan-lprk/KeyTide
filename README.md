# Keytide

Keytide 是一款面向 macOS 13+ 的原生菜单栏应用，在本地统计键盘与鼠标交互，并用活动日历、趋势图和 3D 成长键盘呈现使用记录。

默认仅保存聚合统计。可选的「真实回放记录」会跨 App 保存物理键位、按下／松开顺序和毫秒时间，仅在本机加密保存，长期保留直到手动删除。这些序列可能推断输入内容，包括敏感输入；开启前会明确说明，可在设置或菜单栏右键菜单查看状态，并提供停止和删除控制。不读取文本字段、点击坐标、完整鼠标轨迹或剪贴板内容；回放明细不上传、不进入 Analytics，也不加入普通统计导出。

## 功能

- **菜单栏面板**：今日按键与点击、KPS／CPS、常用键、历史趋势和鼠标明细；可选择标准／极客风格，自定义菜单栏统计项与数字格式。
- **活动记录**：今天、7 天与 30 天趋势，日期浏览、按键与点击明细、月度活动日历、常用键和累计洞察，可跳转到截至所选日期的键盘成长。
- **应用统计**：按时间范围查看分应用聚合数据，支持名称／bundle ID 搜索、指标排序和应用详情中的键位分布与 Interaction Profile。
- **Keyboard Studio**：77 键 Mac／机械 3D 模型，累计、单日与日期区间显示，键位次数／占比／排名，以及逐日成长回放。有本机顺序明细的日期按原始顺序加速回放，缩短长时间空闲，记录较多的一天约 8 秒；原始毫秒时间保持不变，重复按键及松开事件驱动按压和逐步成长；没有明细的日期仅展示逐日成长，不生成模拟输入。单日模式也可回放所选日期。旧历史无法补回原始顺序。
- **窗口内试打**：鼠标点击或实体按键触发短暂下沉回弹；虚拟点击不写入统计，不新增全局输入监听。
- **键盘图片**：两种模型均支持 PNG 导出、复制和不含日期／次数的干净图片，附项目仓库署名。
- **数据与设置**：本地 JSON 导入／导出、鼠标距离校准、通知阈值和开机启动。

统计包括鼠标各类点击、移动与滚动距离、Scroll Session，以及亮度、音量、播放等媒体键。每键与组合键次数是聚合记录，不是输入文本或原始输入序列。当前产品为独立 macOS App，不提供多设备同步或独立插件。

3D 按需渲染并限制缓存；菜单的实时波形只在显示期间采样，关闭后清理。低功耗是设计目标，最终性能与能耗验收单独进行。产品 Analytics 默认关闭，未同意时不初始化 PostHog；输入统计与分应用数据不得上传至 Analytics。

## 安装与更新

从本仓库的 [Releases](https://github.com/Xuan-lprk/KeyTide/releases) 下载可用版本，将 DMG 内的 `Keytide.app` 拖到 Applications，或解压 ZIP 后复制 App。

首次启动会显示简洁的使用指引，介绍菜单栏入口、隐私边界和授权状态；可稍后设置，也可在设置 → 通用中重新打开。只有监听成功才显示“准备好了”，开机启动由用户主动选择。

首次使用需按 App 引导为 **KeytideHelper** 授予辅助功能权限。当前分发采用 ad-hoc 签名，未经过 Apple 公证；这不同于 Developer ID 分发。不要通过关闭系统安全检查或批量移除隔离属性安装。

App 内“检查更新”打开本仓库 Releases 页面，下载并替换属于手动更新。Sparkle 自动检查与 App 内更新均关闭。

## 开发

使用 Swift、AppKit 和部分 SwiftUI：

```bash
swift test

xcodebuild \
  -project Keytide.xcodeproj \
  -scheme Keytide \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath "$PWD/build/Development/DerivedData" \
  build
```

构建不会启动 App。普通启动会安装／更新 Helper 并注册 LaunchAgent；不要同时运行两份主 App。Debug 的 `--debug-gui-acceptance` 跳过 Helper 安装与旧权限迁移，但仍可能连接已授权的 Helper、写入正式统计并按用户选择运行 Analytics，因此不是离线数据沙盒。详见 [开发指南](AGENTS.md)。

自动化测试、构建和静态包检查不能替代真实授权、采集、VoiceOver、升级及能耗验收。各轮本机日志保存在忽略的 `build/`，不以历史测试数量表示当前版本已完成全部验收。

## 项目与文档

- [开发指南](AGENTS.md)：架构、隐私与操作边界。
- [原生 Helper](KeytideHelper/README.md)：独立源码构建、测试和 XPC 边界。
- [文档索引](docs/README.md)。
- [macOS 打包与发布](docs/macos-release.md)。
- [图标资源](Design/Keytide-Icon-v1/README.md)。

## 名称与兼容

主工程、scheme 和产品为 `Keytide`。主 App 标识符为 `com.xuanlprk.KeyTide`；Helper、Mach service 和 LaunchAgent 为 `com.xuanlprk.KeyTide.helper`。Helper 安装于 `~/Library/Application Support/Keytide/Helper/KeytideHelper.app`。

改名前的主 App 偏好设置域会一次性复制到新域，已有新值优先，旧域保留；旧安装身份仅用于兼容迁移。新 Helper 的权限需要重新授予，不能自动继承旧身份。真实升级连续性需要独立验收。

## Upstream 与许可

本项目基于 [debugtheworldbot/keyStats](https://github.com/debugtheworldbot/keyStats) 继续开发。许可信息见 [LICENSE](LICENSE) 和 [LICENSE-MIT](docs/LICENSE-MIT)。
