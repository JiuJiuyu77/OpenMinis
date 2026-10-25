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

    var command: String {
        var parts = ["make -j4 package"]
        if scheme != "rootful" { parts.append("THEOS_PACKAGE_SCHEME=\(scheme)") }
        parts.append("FINALPACKAGE=1")
        if !archs.isEmpty { parts.append("ARCHS=\(archs)") }
        if !target.isEmpty { parts.append("TARGET=\(target)") }
        if !extraFlags.isEmpty { parts.append(extraFlags) }
        var cmd = parts.joined(separator: " ")
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
    }

    init() {
        projectPath = defaults.string(forKey: Keys.project) ?? ""
        scheme = defaults.string(forKey: Keys.scheme) ?? "rootless"
        archs = defaults.string(forKey: Keys.archs) ?? "arm64"
        cleanBeforeBuild = defaults.bool(forKey: Keys.clean)
        extraFlags = defaults.string(forKey: Keys.extra) ?? ""
    }

    func persist() {
        defaults.set(projectPath, forKey: Keys.project)
        defaults.set(scheme, forKey: Keys.scheme)
        defaults.set(archs, forKey: Keys.archs)
        defaults.set(cleanBeforeBuild, forKey: Keys.clean)
        defaults.set(extraFlags, forKey: Keys.extra)
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
            appendLog("✗ 未找到原生工具链。请在「编译 → 工具链」里下载 Theos 运行时，或把运行时放进 App 的 NativeToolchain 目录。")
            return
        }
        running = true
        logLines.removeAll()
        persist()

        let config = NativeBuildConfig(projectPath: projectPath, scheme: scheme, archs: archs,
                                       cleanBeforeBuild: cleanBeforeBuild, extraFlags: extraFlags)
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
