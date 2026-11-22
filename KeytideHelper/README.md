# Keytide 原生采集包

`KeytideHelper/` 可以作为 macOS 13+、Swift 5.9+ 的独立 SwiftPM 包构建和测试，无第三方依赖。SwiftPM 与正式 Xcode `helper` target 编译同一份采集、统计和写入源码。

## 构建与测试

在 Keytide 仓库根目录运行：

```sh
swift build --package-path KeytideHelper \
  --scratch-path build/HelperStandalone/SwiftPM --product KeytideHelper

swift test --package-path KeytideHelper \
  --scratch-path build/HelperStandalone/SwiftPM
```

也可只取本目录，在该目录执行 `swift build` 和 `swift test`。`Tests/` 使用合成输入、隔离偏好和内存密钥，验证 payload、退出后台运行、两种回放写入及重连恢复，无需安装服务或请求系统权限。

新增 SwiftPM 测试文件时，同时在主工程 `PBXFileSystemSynchronizedBuildFileExceptionSet` 的 helper 排除项中列出具体相对路径；Xcode 的同步目录不会自动把整个 `Tests` 目录当作测试 target。

独立的是**源码构建和测试边界**。SwiftPM 输出的是开发用裸可执行文件，不是可直接替换已安装服务的签名 `.app`，也没有自动安装、LaunchAgent 或授权步骤。不要用 `swift run` 验证正在使用的采集服务，以免与现有 Mach service 冲突。正式 App 打包仍使用 Xcode 的 `helper` target，以及原有 vendored helper、签名和嵌入脚本。

## 职责与依赖

| 层 | 源码 | 职责 |
| --- | --- | --- |
| 进程入口 | `main.swift` | 启动原有 XPC listener 与 run loop |
| 原生采集 | `EventTapController.swift` | listen-only EventTap、移动采样、权限查询和显式权限请求 |
| 事件字段 | `PayloadBuilder.swift`、`HelperPayloadFields.swift` | 受限的内存 payload，不读取输入文本 |
| 输入语义 | `ButtonRoleClassifier.swift`、`SystemMediaKey.swift` | 鼠标逻辑按键和媒体键语义 |
| 本机通信 | `HelperXPCListener.swift`、`HelperProtocols.swift` | 签名及 UID 校验、单活动连接、聚合快照和可见触控板预览 |
| 服务身份 | `HelperLocations.swift` | 既有 Bundle ID、Mach service、安装路径和协议版本 |
| 采集与保存 | `HelperInputService.swift`、`InputEventAggregator.swift`、`StatsManager.swift` | 键鼠聚合、分应用归因、原格式保存和后台采集控制 |
| 回放记录 | `HelperKeyReplayWriter.swift`、`HelperTrackpadService.swift`、`TrackpadRecording.swift` | 独立授权后批量加密写入本机 |
| 生命周期 | `HelperIdleSupervisor.swift` | 仅在存在前台连接或已授权后台采集时保持运行 |

主 App 的 `HelperSupervisor` 负责安装、cdhash 和 LaunchAgent。主 App 的统计实例显示 Helper 提供的快照，触控板画布和两种回放留在主 App。统计保留既有 UserDefaults 键和格式，回放保留原有加密文件和密钥标识。

「退出后继续统计」默认开启。欢迎引导和通用设置可修改同一个选项，已有的关闭选择会保留。主 App 完成权限设置、开始采集后，才注册退出后采集。随后用户级 LaunchAgent 持续运行 Helper，并在下次登录时恢复。Helper 恢复时检查用户选择、已生效状态和启动标记。键盘、触控板细节记录仍分别授权。没有界面连接时，Helper 停止推送展示快照和实时预览。后台开关关闭后，退出主 App 会停止采集，Helper 在空闲后退出。

保持现有身份：

- 主 App：`com.xuanlprk.KeyTide`
- Helper／Mach service／LaunchAgent：`com.xuanlprk.KeyTide.helper`
- XPC interface version：`4`
- 安装位置：`~/Library/Application Support/Keytide/Helper/KeytideHelper.app`

签名校验没有放宽，仍只接受既有主 App identity、有效签名和相同用户 UID。构建本包不会运行安装器，不应据此宣称已验证 TCC 授权连续性或真实 XPC 生命周期。
