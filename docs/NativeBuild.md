# NativeBuild · 原生编译（不经过 iSH）

本仓库是 **OpenMinis（Minis）** 的派生版本，新增了一条「原生工具链」编译路径，
并把 MT 智能体（`susu123oss/MT-Agent`）的开发环境接进来作为编译器。

## 为什么要这条路径

Minis 原本的 `shell_execute` 跑在 iSH（Alpine Linux 模拟层）里：

- 上架沙盒不允许 `posix_spawn` 任意 Mach-O，所以只能模拟 Linux，再在模拟层里装 clang；
- 模拟层里的 clang 打的是 **Linux ELF**，产物不是 iOS 原生 `.deb`，跟 Theos 的原生链路是两套；
- 交叉编译 iOS 产物要额外的 SDK / ld64 / ldid，模拟层里跑得慢且容易断。

MT 智能体走的是另一条路：它是 TrollStore 包（`platform-application` + `no-sandbox`），
`posix_spawn` 真实的 iOS Mach-O 工具链（clang / ld64 / dpkg-deb / ldid / bash）。
本仓库把这条路径搬进 Minis。

## 结构

```
src/ios/Agent/NativeBuild/
├── NativeToolchain.swift      工具链探测 + 环境变量（THEOS / CA_THEOS_*）
├── NativeCommandRunner.swift  posix_spawn + 管道，逐行日志、超时、整组终止
├── NativeBuildService.swift   构建编排（make package）、产物扫描、UI 状态
├── NativeBuildTool.swift      native_build 工具（Agent 可直接调用）
└── BuildWorkbenchView.swift   可视化界面（设置 › Agent 工具 › 编译工作台）
```

集成点（3 处，都是加一片代码，不改动原有逻辑）：

| 文件 | 改动 |
|---|---|
| `Agent/Chat/AIChatViewModel+ToolDefinitions.swift` | `makeAgentTools()` 末尾 `tools.append(NativeBuildTool.definition)` |
| `Agent/Chat/AIChatViewModel+ConcurrentTools.swift` | 工具分发表新增 `case NativeBuildTool.name` |
| `Views/Settings/ToolsSettingsView.swift` | 设置页插入 `nativeBuildSection` 入口 |
| `Minis.xcodeproj/project.pbxproj` | `Agent/NativeBuild` 作为 `PBXFileSystemSynchronizedRootGroup` 挂到 Minis target |

## 工具链从哪来

`NativeToolchain` 依次找：

1. `App.app/NativeToolchain/`（随包分发，体积 +224MB）
2. `~/Library/Application Support/NativeToolchain/`
3. **`/var/mobile/Library/Application Support/CodexApp/`** —— MT 智能体已下载的运行时（推荐，零额外体积）

命中条件：目录下存在 `makefiles/common.mk`（Theos 特征）。

环境变量与 MT 的内嵌约定一致：`THEOS`、`CA_THEOS_EMBEDDED=1`、`CA_THEOS_HELPER=Helpers/theos-helper`、
`CA_THEOS_MAKE/CLANG/CLANGXX/DPKG_DEB/TAR/GZIP/XZ/PERL`、`PATH` 前置 `Helpers` + `Helpers/TheosCompat` + `Helpers/TheosCoreCompat`。
这些是 MT 的 makefile 走 forkless 分支所必需的。

## 权限要求

原生路径只在**带 TrollStore / 越狱权限**的安装包里可用：

```xml
<key>com.apple.private.security.no-sandbox</key><true/>
<key>platform-application</key><true/>
<key>get-task-allow</key><true/>
```

没有这些权限时 `NativeToolchain.isAvailable` 为 false，界面显示「未找到原生工具链」，
`shell_execute` 的 iSH 路径完全不受影响 —— 也就是说：**App Store 版本行为不变**。

## 出包

`.github/workflows/trollstore-ipa.yml`：macOS runner 用 `xcodebuild` 出 unsigned `.app`，
再用 `ldid` 打上 `Configs/TrollStore.entitlements`，压成 `.tipa` 作为 artifact。
