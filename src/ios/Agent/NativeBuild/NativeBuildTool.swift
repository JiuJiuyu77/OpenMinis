//
//  NativeBuildTool.swift
//  Minis — native_build 工具（Agent 直接调原生工具链）
//
//  与 shell_execute 的区别：这条路径不经过 iSH（不模拟 Linux），
//  直接把命令交给 App 进程内的真实 iOS 工具链执行，产物是设备上的 .deb。
//

import Foundation

enum NativeBuildTool {

    static let name = "native_build"

    static var definition: AgentToolDefinition {
        AgentToolDefinition(
            name: name,
            description: """
            Build an iOS tweak project with the on-device NATIVE toolchain (Theos: clang/ld64/dpkg-deb), \
            without the iSH Linux sandbox. Use this instead of shell_execute when the user wants to compile \
            a Theos project into a .deb: it runs `make package` on the device filesystem and returns the \
            produced .deb paths plus the build log. Paths are real device paths (e.g. \
            /var/mobile/Documents/MyTweak), not iSH paths (/var/minis/...).
            """,
            parameters: [
                "tool_title": AgentToolParam(type: .string,
                                             description: "A concise 5-10 word summary of what this tool call does, in the user's language (e.g. '编译 MyTweak 为 deb')."),
                "path": AgentToolParam(type: .string,
                                       description: "Absolute device path of the project directory (must contain a Theos Makefile)."),
                "scheme": AgentToolParam(type: .string,
                                         description: "Packaging scheme: rootless (default), rootful, or roothide.",
                                         enumValues: ["rootless", "rootful", "roothide"]),
                "archs": AgentToolParam(type: .string,
                                        description: "Target architectures, default arm64. Use 'arm64 arm64e' for both."),
                "clean": AgentToolParam(type: .boolean,
                                        description: "Run `make clean` before packaging. Default false."),
                "extra": AgentToolParam(type: .string,
                                        description: "Extra make arguments appended verbatim, e.g. 'DEBUG=0'."),
                "timeout": AgentToolParam(type: .integer,
                                          description: "Timeout in seconds (default 1800)."),
                "tool_note": AgentToolParam(type: .string,
                                            description: "Optional one-line note shown to the user."),
            ],
            required: ["tool_title", "path"],
            propertyOrdering: ["tool_title", "path", "scheme", "archs", "clean", "extra", "timeout", "tool_note"]
        )
    }

    /// 供 AIChatViewModel+ConcurrentTools 的分发分支调用。
    static func perform(args: [String: Any]) async -> (text: String, ok: Bool) {
        let path = (args["path"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        var isDir: ObjCBool = false
        guard !path.isEmpty,
              FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else {
            return ("Error: project directory not found at \(path.isEmpty ? "(empty)" : path)", false)
        }

        let toolchain = NativeToolchain.shared
        guard toolchain.isAvailable else {
            return ("""
            Error: native toolchain unavailable.
            No usable Theos runtime / shell was found. The user must download the runtime first \
            (Editor: Settings › Agent Tools › 编译工作台 → 下载运行时), or install the runtime into \
            Library/Application Support/NativeToolchain.
            Runtime root searched: \(NativeToolchain.candidateRoots().map(\.path).joined(separator: ", "))
            """, false)
        }

        let scheme = (args["scheme"] as? String) ?? "rootless"
        let archs = (args["archs"] as? String) ?? "arm64"
        let clean = (args["clean"] as? Bool) ?? false
        let extra = (args["extra"] as? String) ?? ""
        let timeout = TimeInterval((args["timeout"] as? Int) ?? 1800)

        let config = NativeBuildConfig(projectPath: path,
                                       scheme: scheme,
                                       archs: archs,
                                       cleanBeforeBuild: clean,
                                       extraFlags: extra,
                                       timeout: timeout > 0 ? timeout : 1800)

        let result = await NativeBuildService.runBuild(config)

        var lines: [String] = []
        lines.append(result.ok ? "✓ \(result.message)" : "✗ \(result.message)")
        lines.append("工程：\(path)（\(toolchain.detectKind(path).rawValue)）")
        lines.append("命令：\(config.command.replacingOccurrences(of: "\n", with: " ; "))")
        lines.append("用时：\(String(format: "%.1f", result.seconds)) 秒，退出码 \(result.exitCode)")
        if result.artifacts.isEmpty {
            lines.append("产物：无")
        } else {
            lines.append("产物：")
            for artifact in result.artifacts {
                let attrs = try? FileManager.default.attributesOfItem(atPath: artifact)
                let size = (attrs?[.size] as? Int64) ?? 0
                lines.append("  \(artifact)  (\(ByteCountFormatter.string(fromByteCount: size, countStyle: .file)))")
            }
        }
        lines.append("")
        lines.append("--- 构建日志（尾部 4000 字）---")
        lines.append(String(result.log.suffix(4000)))
        return (lines.joined(separator: "\n"), result.ok)
    }
}
