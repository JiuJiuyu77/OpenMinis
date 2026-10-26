//
//  BuildObfuscation.swift
//  Minis — 构建混淆强度（OLLVM）
//
//  为什么单独一个文件：混淆强度是**编译期**参数，既要在可视化构建工作台里
//  出现，也要能被 native_build 工具按名字指定，还要写进 make 命令行。把
//  「强度 → 具体 -mllvm 参数」的映射集中在这里，界面与工具就不会各写一份
//  互相矛盾的参数表。
//
//  注意：这些参数只有在工具链里装了 OLLVM 前端（`ios.ollvm` 能力）时才有
//  意义。没有 OLLVM 时强开会链接失败，所以 UI 会先查能力再允许选择。
//

import Foundation

/// 混淆强度。数字越大越难逆，代价是体积与编译时间。
enum BuildObfuscation: String, CaseIterable, Identifiable {
    case off
    case light
    case balanced
    case strong
    case paranoid

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .off: return AppLocalized("Off")
        case .light: return AppLocalized("Light")
        case .balanced: return AppLocalized("Balanced")
        case .strong: return AppLocalized("Strong")
        case .paranoid: return AppLocalized("Paranoid")
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
            return AppLocalized("Flattening, bogus control flow and instruction substitution with more iterations.")
        case .paranoid:
            return AppLocalized("Every pass at maximum iterations, plus string encryption hints. Slowest and largest.")
        }
    }

    /// `-mllvm` flags handed to clang through the Theos toolchain.
    var compilerFlags: [String] {
        switch self {
        case .off:
            return []
        case .light:
            return ["-mllvm", "-fla"]
        case .balanced:
            return ["-mllvm", "-fla", "-mllvm", "-bcf"]
        case .strong:
            return ["-mllvm", "-fla", "-mllvm", "-bcf", "-mllvm", "-sub",
                    "-mllvm", "-bcf_prob=60", "-mllvm", "-bcf_loop=2"]
        case .paranoid:
            return ["-mllvm", "-fla", "-mllvm", "-bcf", "-mllvm", "-sub",
                    "-mllvm", "-bcf_prob=90", "-mllvm", "-bcf_loop=3",
                    "-mllvm", "-split=3", "-mllvm", "-sobf", "-mllvm", "-sub_loop=3"]
        }
    }

    /// Short machine-readable summary for logs / tool output.
    var flagSummary: String {
        compilerFlags.isEmpty ? "none" : compilerFlags.filter { !$0.hasPrefix("-mllvm") }.joined(separator: " ")
    }

    /// Whether this level needs an OLLVM-capable compiler.
    var requiresOLLVM: Bool { self != .off }

    static func parse(_ raw: String?) -> BuildObfuscation {
        guard let raw, let value = BuildObfuscation(rawValue: raw) else { return .off }
        return value
    }
}
