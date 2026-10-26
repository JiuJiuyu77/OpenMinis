//
//  BuildObfuscation.swift
//  Minis — 构建混淆强度（OLLVM）
//
//  为什么单独一个文件：混淆强度是**编译期**参数，既要在可视化构建工作台里
//  出现，也要能被 native_build 工具按名字指定，还要写进 make 命令行。把
//  「强度 → 具体 -mllvm 参数」的映射集中在这里，界面与工具就不会各写一份
//  互相矛盾的参数表。
//
//  注意：这些参数只有在工具链里装了 OLLVM 前端（`compiler.ollvm.frontend`）
//  时才有意义。没有 OLLVM 时强开会得到一堆 `unknown argument -mllvm`，比
//  直接失败更难查，所以 UI 会先查能力、工具也会预检。
//

import Foundation

/// 单个混淆 Pass 开关。`-fla` 控制流平坦化、`-bcf` 虚假控制流、
/// `-sub` 指令替换、`-split` 基本块分割、`-sobf` 字符串加密。
enum ObfuscationPass: String, CaseIterable, Identifiable, Codable {
    case flatten      // -fla
    case bogusFlow    // -bcf
    case substitution // -sub
    case split        // -split
    case stringEncrypt // -sobf
    case indirectBranch // -ibr
    case indirectCall   // -icall

    var id: String { rawValue }

    var mllvmFlag: String {
        switch self {
        case .flatten: return "-fla"
        case .bogusFlow: return "-bcf"
        case .substitution: return "-sub"
        case .split: return "-split"
        case .stringEncrypt: return "-sobf"
        case .indirectBranch: return "-ibr"
        case .indirectCall: return "-icall"
        }
    }

    var displayName: String {
        switch self {
        case .flatten: return AppLocalized("Control-flow flattening")
        case .bogusFlow: return AppLocalized("Bogus control flow")
        case .substitution: return AppLocalized("Instruction substitution")
        case .split: return AppLocalized("Basic-block splitting")
        case .stringEncrypt: return AppLocalized("String encryption")
        case .indirectBranch: return AppLocalized("Indirect branch")
        case .indirectCall: return AppLocalized("Indirect call")
        }
    }
}

/// 混淆强度。数字越大越难逆，代价是体积与编译时间。
enum BuildObfuscation: String, CaseIterable, Identifiable, Codable {
    case off
    case light
    case balanced
    case strong
    case paranoid
    case extreme

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .off: return AppLocalized("Off")
        case .light: return AppLocalized("Light")
        case .balanced: return AppLocalized("Balanced")
        case .strong: return AppLocalized("Strong")
        case .paranoid: return AppLocalized("Paranoid")
        case .extreme: return AppLocalized("Extreme")
        }
    }

    var explanation: String {
        switch self {
        case .off:
            return AppLocalized("No obfuscation passes. Use this when OLLVM is not installed.")
        case .light:
            return AppLocalized("Control-flow flattening only. Smallest size cost, fastest builds.")
        case .balanced:
            return AppLocalized("Flattening plus bogus control flow. A good default for release builds.")
        case .strong:
            return AppLocalized("Flattening, bogus control flow, instruction substitution and block splitting with more iterations.")
        case .paranoid:
            return AppLocalized("Every pass at maximum iterations, including string encryption. Slowest and largest.")
        case .extreme:
            return AppLocalized("Everything in Paranoid plus indirect branch/call obfuscation. Expect a much larger binary and a long build; verify the app still launches before shipping.")
        }
    }

    /// 这一档启用的 Pass 集合。
    var passes: [ObfuscationPass] {
        switch self {
        case .off: return []
        case .light: return [.flatten]
        case .balanced: return [.flatten, .bogusFlow]
        case .strong: return [.flatten, .bogusFlow, .substitution, .split]
        case .paranoid: return ObfuscationPass.allCases.filter { $0 != .indirectBranch && $0 != .indirectCall }
        case .extreme: return ObfuscationPass.allCases
        }
    }

    /// 迭代相关参数（越强越多）。
    private var tuningFlags: [String] {
        switch self {
        case .off: return []
        case .light: return []
        case .balanced: return ["-bcf_prob=45", "-bcf_loop=2"]
        case .strong: return ["-bcf_prob=60", "-bcf_loop=2", "-split_num=3", "-sub_loop=2"]
        case .paranoid: return ["-bcf_prob=90", "-bcf_loop=3", "-split_num=4",
                                "-sub_loop=3", "-sobf_prob=80"]
        case .extreme: return ["-bcf_prob=95", "-bcf_loop=3", "-split_num=4",
                               "-sub_loop=3", "-sobf_prob=90", "-ibr_prob=60", "-icall_prob=60"]
        }
    }

    /// `-mllvm` flags handed to clang through the Theos toolchain.
    var compilerFlags: [String] {
        guard self != .off else { return [] }
        var flags: [String] = []
        for pass in passes {
            flags.append(contentsOf: ["-mllvm", pass.mllvmFlag])
        }
        for tuning in tuningFlags {
            flags.append(contentsOf: ["-mllvm", tuning])
        }
        return flags
    }

    /// Short machine-readable summary for logs / tool output.
    var flagSummary: String {
        guard !compilerFlags.isEmpty else { return "none" }
        let named = passes.map(\.rawValue).joined(separator: ", ")
        return named
    }

    /// Whether this level needs an OLLVM-capable compiler.
    var requiresOLLVM: Bool { self != .off }

    static func parse(_ raw: String?) -> BuildObfuscation {
        guard let raw, let value = BuildObfuscation(rawValue: raw) else { return .off }
        return value
    }
}

/// 额外的代码保护选项：符号剥离 + 字符串加密。这两项与 OLLVM 强度正交，
/// 可以单独开（例如没有 OLLVM 时用 `strip` 至少去掉符号表）。
struct BuildProtection: Equatable {
    /// 编译后对产物执行 `strip -x`（去掉局部符号）。
    var stripSymbols: Bool = false
    /// 让 Clang 以 `-O2 -fvisibility=hidden` 编译，减少导出符号。
    var hideSymbols: Bool = false
    /// 通过 OLLVM 的 `-sobf` 加密字符串常量（等价于 light 档以上含 sobf）。
    var encryptStrings: Bool = false

    var isDefault: Bool { !stripSymbols && !hideSymbols && !encryptStrings }

    /// 追加到 CFLAGS 的参数（编译器层面可见性/字符串加密）。
    var compilerFlags: [String] {
        var flags: [String] = []
        if hideSymbols { flags.append(contentsOf: ["-fvisibility=hidden", "-fvisibility-inlines-hidden"]) }
        if encryptStrings { flags.append(contentsOf: ["-mllvm", "-sobf"]) }
        return flags
    }
}
