# 本分支做了什么

这是 **Minis（OpenMinis，GPL-3.0）** 的派生分支，做了两件事：

1. **移除 MT 智能体的 AI 能力**：不再依赖 `MT-Agent` 那个闭源包（它的仓库只有 README，
   二进制注入无法真正删代码，界面/引擎拦截总有残留）。AI 界面在 Minis 里本就不来自 MT，
   本分支不引入任何 MT 的 AI 代码。
2. **把编译能力搬进 Minis 本身**：新增 `NativeBuild` 模块（见 `docs/NativeBuild.md`），
   直接 `posix_spawn` 设备上的原生 Theos 工具链（clang / ld64 / dpkg-deb / ldid），
   不经过 iSH 的 Linux 模拟层。运行时默认复用 MT 已下载的那份（零额外体积）。

需要 TrollStore / 越狱权限（`no-sandbox` + `platform-application`）才有原生能力；
App Store 包行为不变，`shell_execute` 仍走 iSH。
