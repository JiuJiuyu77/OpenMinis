//
//  NativeBuildService.swift
//  Minis — 编译服务：工程 → make package → .deb
//
//  同时服务两个消费者：
//   · BuildWorkbenchView（可视化界面）
//   · native_build 工具（Agent 直接调用）
//

import Foundation

struct NativeBuildConfig {
    var projectPath: String
    var scheme: String = "rootless"     // rootless / rootful / roothide
    var archs: String = "arm64"
    var cleanBeforeBuild: Bool = false
    var extraFlags: String = ""
    var target: String = ""             // 例：iphone:clang:latest:15.0
    var timeout: TimeInterval = 1800
    /// 混淆强度（OLLVM）。`.off` 时不注入任何 -mllvm 参数。
    var obfuscation: BuildObfuscation = .off
    /// 追加到 CFLAGS/CXXFLAGS 的自定义参数（可视化里的“自定义编译参数”）。
    var cflags: String = ""
    /// 追加到 LDFLAGS 的自定义参数。
    var ldflags: String = ""
    /// 编译并行度；<=0 时用 4。
    var jobs: Int = 4
    /// 只打包、不重新编译（`make package FINALPACKAGE=1` 会增量，这个开关保留
    /// 给“产物已经编好、只需要重打包”的场景）。
    var packageOnly: Bool = false

    /// 拼进 make 命令行的一组变量。保持 key=value 形式，避免依赖 shell 引号。
    var makeVariables: [String] {
        var parts: [String] = []
        if scheme != "rootful" { parts.append("THEOS_PACKAGE_SCHEME=\(scheme)") }
        parts.append("FINALPACKAGE=1")
        if !archs.isEmpty { parts.append("ARCHS=\(archs)") }
        if !target.isEmpty { parts.append("TARGET=\(target)") }

        // 混淆 + 自定义 CFLAGS 合并成一个变量：命令行上不支持 `VAR+=x`
        // （那是 makefile 内部语法），两个 `VAR=` 只会后者覆盖前者。
        var allCFlags: [String] = []
        if obfuscation.requiresOLLVM {
            allCFlags.append(obfuscation.compilerFlags.joined(separator: " "))
        }
        if !cflags.isEmpty { allCFlags.append(cflags) }
        if !allCFlags.isEmpty {
            let merged = allCFlags.joined(separator: " ")
            // 整体加引号，否则 make 会把每个 -mllvm flag 当成独立变量。
            parts.append("ADDITIONAL_CFLAGS=\"\(merged)\"")
            parts.append("ADDITIONAL_OBJCFLAGS=\"\(merged)\"")
            parts.append("ADDITIONAL_CPPFLAGS=\"\(merged)\"")
        }
        if !ldflags.isEmpty { parts.append("ADDITIONAL_LDFLAGS=\"\(ldflags)\"") }
        if !extraFlags.isEmpty { parts.append(extraFlags) }
        return parts
    }

    var command: String {
        let jobCount = jobs > 0 ? jobs : 4
        var head: [String] = []
        if packageOnly {
            head.append("make -j\(jobCount) package")
        } else {
            head.append("make -j\(jobCount) package")
        }
        var cmd = (head + makeVariables).joined(separator: " ")
        if cleanBeforeBuild {
            cmd = "echo '▸ 清理旧产物…'\nmake clean >/dev/null 2>&1 || true\n" + cmd
        }
        return cmd
    }
}

struct NativeBuildResult {
    var ok: Bool
    var exitCode: Int32
    var seconds: Double
    var artifacts: [String]
    var log: String
    var message: String
}

@MainActor
final class NativeBuildService: ObservableObject {

    static let shared = NativeBuildService()

    @Published var projectPath: String
    @Published var scheme: String
    @Published var archs: String
    @Published var cleanBeforeBuild: Bool
    @Published var extraFlags: String
    @Published var obfuscation: BuildObfuscation
    @Published var cflags: String
    @Published var ldflags: String
    @Published var jobs: Int
    @Published var packageOnly: Bool
    @Published var running = false
    @Published var logLines: [String] = []
    @Published var lastResult: NativeBuildResult?
    @Published private(set) var currentPID: pid_t = 0

    private let defaults = UserDefaults.standard

    private enum Keys {
        static let project = "nativeBuild.project"
        static let scheme = "nativeBuild.scheme"
        static let archs = "nativeBuild.archs"
        static let clean = "nativeBuild.clean"
        static let extra = "nativeBuild.extra"
        static let obfuscation = "nativeBuild.obfuscation"
        static let cflags = "nativeBuild.cflags"
        static let ldflags = "nativeBuild.ldflags"
        static let jobs = "nativeBuild.jobs"
        static let packageOnly = "nativeBuild.packageOnly"
    }

    init() {
        projectPath = defaults.string(forKey: Keys.project) ?? ""
        scheme = defaults.string(forKey: Keys.scheme) ?? "rootless"
        archs = defaults.string(forKey: Keys.archs) ?? "arm64"
        cleanBeforeBuild = defaults.bool(forKey: Keys.clean)
        extraFlags = defaults.string(forKey: Keys.extra) ?? ""
        obfuscation = BuildObfuscation.parse(defaults.string(forKey: Keys.obfuscation))
        cflags = defaults.string(forKey: Keys.cflags) ?? ""
        ldflags = defaults.string(forKey: Keys.ldflags) ?? ""
        let storedJobs = defaults.integer(forKey: Keys.jobs)
        jobs = storedJobs > 0 ? storedJobs : 4
        packageOnly = defaults.bool(forKey: Keys.packageOnly)
    }

    func persist() {
        defaults.set(projectPath, forKey: Keys.project)
        defaults.set(scheme, forKey: Keys.scheme)
        defaults.set(archs, forKey: Keys.archs)
        defaults.set(cleanBeforeBuild, forKey: Keys.clean)
        defaults.set(extraFlags, forKey: Keys.extra)
        defaults.set(obfuscation.rawValue, forKey: Keys.obfuscation)
        defaults.set(cflags, forKey: Keys.cflags)
        defaults.set(ldflags, forKey: Keys.ldflags)
        defaults.set(jobs, forKey: Keys.jobs)
        defaults.set(packageOnly, forKey: Keys.packageOnly)
    }

    var toolchainReady: Bool { NativeToolchain.shared.isAvailable }

    var artifacts: [String] {
        guard !projectPath.isEmpty else { return [] }
        return NativeToolchain.shared.artifacts(in: projectPath)
    }

    func appendLog(_ line: String) {
        logLines.append(line)
        if logLines.count > 4000 { logLines.removeFirst(logLines.count - 4000) }
    }

    /// 供 UI 调用：后台跑，状态回主线程。
    func startBuild() {
        guard !running else { return }
        guard !projectPath.isEmpty else {
            appendLog("✗ 请先选择工程目录")
            return
        }
        guard toolchainReady else {
            let roots = NativeToolchain.candidateRoots().prefix(4).map(\.path).joined(separator: "\n  ")
            appendLog("""
            ✗ 未找到原生工具链（缺 Theos 或可用 shell）。
            已搜索：
              \(roots)
            下一步：在下方「工具链诊断」里手动指定 Theos 根目录，或到 设置 → Developer Runtime 安装 Theos。
            """)
            return
        }
        running = true
        logLines.removeAll()
        persist()

        let config = NativeBuildConfig(projectPath: projectPath,
                                       scheme: scheme,
                                       archs: archs,
                                       cleanBeforeBuild: cleanBeforeBuild,
                                       extraFlags: extraFlags,
                                       obfuscation: obfuscation,
                                       cflags: cflags,
                                       ldflags: ldflags,
                                       jobs: jobs,
                                       packageOnly: packageOnly)
        Task { @MainActor in
            let result = await NativeBuildService.runBuild(config) { [weak self] line in
                Task { @MainActor in self?.appendLog(line) }
            } onSpawn: { [weak self] pid in
                Task { @MainActor in self?.currentPID = pid }
            }
            self.running = false
            self.currentPID = 0
            self.lastResult = result
            self.appendLog(result.ok ? "✓ 构建成功 · \(String(format: "%.1f", result.seconds)) 秒"
                                     : "✗ 构建失败（退出码 \(result.exitCode)）")
            for artifact in result.artifacts { self.appendLog("产物：\(artifact)") }
        }
    }

    func cancel() {
        let pid = currentPID
        guard pid > 0 else { return }
        kill(-pid, SIGTERM)
        appendLog("… 已发送终止信号")
    }

    func refreshToolchain() {
        NativeToolchain.shared.resetCache()
    }

    /// 核心：执行一次构建（纯函数式，UI 与工具共用）。
    nonisolated static func runBuild(_ config: NativeBuildConfig,
                                     onLine: ((String) -> Void)? = nil,
                                     onSpawn: ((pid_t) -> Void)? = nil) async -> NativeBuildResult {
        let toolchain = NativeToolchain.shared
        guard toolchain.isAvailable else {
            return NativeBuildResult(ok: false, exitCode: -1, seconds: 0, artifacts: [], log: "",
                                     message: "原生工具链不可用（缺少 Theos 运行时或 shell）")
        }
        let env = toolchain.environment(projectPath: config.projectPath)
        let result = await NativeCommandRunner.run(command: config.command,
                                                   in: config.projectPath,
                                                   environment: env,
                                                   timeout: config.timeout,
                                                   onLine: onLine,
                                                   onSpawn: onSpawn)
        let artifacts = toolchain.artifacts(in: config.projectPath)
        let message: String
        if result.timedOut {
            message = "构建超时（\(Int(config.timeout)) 秒）已终止"
        } else if result.ok {
            message = artifacts.isEmpty ? "构建成功，但没找到 .deb 产物" : "构建成功"
        } else {
            message = "构建失败（退出码 \(result.exitCode)）"
        }
        return NativeBuildResult(ok: result.ok, exitCode: result.exitCode,
                                 seconds: result.duration, artifacts: artifacts,
                                 log: result.output, message: message)
    }
}
