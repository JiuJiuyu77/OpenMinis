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
├── BuildObfuscation.swift     OLLVM 混淆强度预设（off/light/balanced/strong/paranoid）
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

### 探测顺序（v1.15 build 12 起）

0. **用户手动指定的根目录**（`nativeToolchain.rootOverride`，设置页「手动修复」）
1. `DeveloperRuntime/installed/*`（勾选「优先使用自定义 Runtime」时排在最前）
2. `App.app/NativeToolchain/`
3. `~/Library/Application Support/NativeToolchain/`
4. `CodexApp/PreparedRuntimes/*`、`RuntimeDownloads/Theos`、`ManagedRuntime`

实际设备上 MT 的布局是 `PreparedRuntimes/TheosRuntime/theos/makefiles/common.mk`，
即 Theos 在**子目录**里，所以候选根会逐个展开子目录。旧实现只扫到
`PreparedRuntimes` 这一层就停了，这是「找不到原生工具链」的根因。

### 找不到工具链时怎么修

工具链是否可用有两个必要条件：Theos 根存在 **且** 找到可用的 shell。
MT 的运行时只带 `usr/bin/zsh`（没有 `bash`），旧实现只找 `bash`，
于是 `isAvailable` 恒为 false。现在会依次找 `usr/bin` 与 `bin` 下的
`zsh / bash / sh`，以及 `/var/jb/usr/bin`。

### 工具名别名与 shim（`clang-16` → `clang`）

MT 的 TheosRuntime 只带**带版本号**的编译器：`clang-16` / `clang++-16` /
`clang-cpp-16`，没有裸 `clang`；`ld` 只是 `ld64` 的软链。Theos 的 makefile
调用 `CC=clang` / `LD=ld`，所以“工具链已识别”之后仍会第一步就报
`clang: command not found`。现在：

- `findTool` 先按别名表（`clang-16`…`clang-18`、`ld64`）解析，再退化为
  目录里任意 `name-<数字>` 的可执行文件；
- 新增按需生成的 shim 目录 `Library/Application Support/MinToolchainShim`，
  为 `clang / clang++ / cc / c++ / ld / ld64 / ldid / dpkg-deb / make / ar /
  strip` 建立符号链接，并把它放在 `PATH` 最前面；
- 诊断列表多一行「Tool shims」，可直接看到 shim 目录是否存在。

切换「默认执行器 / 优先使用自定义 Runtime / 沙箱模式」时会清掉工具链探测缓存，
不需要重启 App 就能生效。

设置页与编译工作台都提供「重新检测并显示诊断」：

- 逐项显示 Manual path / Theos / Shell / SDK / clang / make / ldid / dpkg-deb / Runtime bin 的 ✓ / ✗；
- 可直接填入工具链根目录（含 `theos/` 或 `usr/bin` 的那一层）并「套用」或「清除」；
- `PATH` 现在包含 `<theos 上一层>/usr/bin`，否则 `make` 起来后找不到 `clang`/`ldid`。

### 可视化构建的更多选项

| 选项 | 说明 |
|---|---|
| 混淆强度 | `off / light / balanced / strong / paranoid`，映射到 OLLVM 的 `-fla/-bcf/-sub/-split/-sobf`；需要装 OLLVM 运行时 |
| 自定义 CFLAGS / LDFLAGS | 合并后作为单个 `ADDITIONAL_CFLAGS` 传给 make（命令行不支持 `VAR+=`） |
| 并行度 | `make -jN`，默认 4 |
| 仅打包 | 复用已有产物，只跑 `make package FINALPACKAGE=1` |

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
