# Developer Runtime（开发运行时安装器）

本文件描述本分支新增的 **Developer Runtime** 模块：在 Minis 内部下载、校验、安装
并管理 iOS 开发工具链运行时（Theos、OLLVM、ReverseTools 等）。它只做“工具链
管理”，不引入 MT-Agent 的 AI / 聊天 / 账户 / Agent 层。

## 为什么需要它

Minis 原本没有“安装 Theos / OLLVM”的能力，而 iOS 上的编译与签名依赖一套体积很大的
原生工具链（clang、iPhoneOS SDK、ld64、ldid、dpkg-deb）。这些工具不适合打包进 IPA，
因此按运行时清单（runtime manifest）在设备上按需下载安装。

## 组成

| 文件 | 职责 |
|---|---|
| `src/ios/Agent/Runtime/RuntimeManifest.swift` | 解析线上 schema 4 清单（含镜像与本地缓存回退），按 compiler → core → tools 排序 |
| `src/ios/Agent/Runtime/RuntimeTarGzExtractor.swift` | 纯 Foundation + zlib 的流式 `tar.gz` 解包（长文件名、符号链接、多 gzip member、进度、取消） |
| `src/ios/Agent/Runtime/DeveloperRuntimeManager.swift` | 下载（边下边算 SHA-256）、校验、staging 解包、原子替换、移除、取消与清理 |
| `src/ios/Views/Settings/DeveloperRuntimeSettingsView.swift` | 设置页：分组列表、安装/更新/移除、进度、错误、占用空间 |
| `src/ios/Views/Settings/SettingsSheet.swift` | 新增 “Developer Runtime” 入口 |

## 行为要点

- **只接受 `tar.gz` 归档的运行时**。清单里 `codex` 发布的是 `.deb`，UI 会明确标记为
  “此运行时以 Debian 包发布，无法在本页面安装”，不会先下载 100MB 再失败。
- **完整性**：下载过程中流式计算 SHA-256，与清单值不一致即丢弃；`.part` 文件原子落盘。
- **安全边界**：
  - 拒绝路径穿越（`..`、绝对路径）；
  - 符号链接只允许指向安装根目录内部，否则跳过并记录；
  - tar 缺少终止块或 gzip 流被截断时报 `truncated`，不静默接受。
- **解包位置**：解包根即运行时根。Theos 的 `theos/`（含 `makefiles`、`sdks`）与
  `usr/bin` 工具可直接用于 `PATH`；页面会显示实际安装根、SDK 路径与可复制的命令。

## 权限边界

安装后的工具链要真正执行编译，需要 TrollStore / 越狱环境的
`no-sandbox` + `platform-application` 权限（见 `Configs/TrollStore.entitlements`）。
未签名 / App Store 沙盒环境下，本模块只负责下载与文件管理，编译能力不可用。

## 验证方式（本机可复现）

```sh
swiftc -typecheck \
  src/ios/Agent/Runtime/RuntimeTarGzExtractor.swift \
  src/ios/Agent/Runtime/RuntimeManifest.swift \
  src/ios/Agent/Runtime/DeveloperRuntimeManager.swift \
  src/ios/Views/Settings/DeveloperRuntimeSettingsView.swift
```

在设备上、不经过 Xcode 的额外验证：

- 真实清单解码：8 个运行时，7 个可安装（`codex` 为 `.deb`）。
- 真实 Theos 归档（224,552,345 字节，SHA-256 与清单一致）：解包约 40 秒，
  971 MB / 23,858 文件 / 1,198 符号链接，SDK 位于 `theos/sdks/iPhoneOS16.5.sdk`。
- 真实 OLLVM 归档（约 27 MB）：解包 0.7 秒，89 MB / 196 文件。
- 安全用例：路径穿越被拒、符号链接逃逸被阻断、截断与缺终止块均报 `truncated`。

## 构建提示（CI）

`.github/workflows/ios-unsigned-ipa.yml`（手动触发）会在 macOS runner 上按
`BUILDING.md` 顺序构建原生依赖并产出未签名 IPA。注意 iSH 的 arm64 VDSO 目标硬编码
`-fuse-ld=lld`，Homebrew 的 `llvm` keg 不含 `ld.lld`，因此必须额外安装 `lld`。
