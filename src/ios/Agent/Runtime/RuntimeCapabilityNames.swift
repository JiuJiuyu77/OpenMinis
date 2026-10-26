//
//  RuntimeCapabilityNames.swift
//  Minis — 运行时能力标识的单一事实来源
//
//  为什么需要它：同一个 OLLVM 运行时在三个地方被判断过，三个地方各写了一
//  串不同的字符串（`ios.ollvm` / `ollvm` / `compiler.ollvm.frontend`），而
//  manifest 实际发布的是 `compiler.ollvm.frontend` +
//  `compiler.ollvm.obfuscation` + `compiler.ollvm.ios-artifact`。于是
//  「已经装好 OLLVM」在编译工作台里显示成「未安装」，选了混淆强度后又被
//  工具拒绝。把判断集中到这里，界面、工具、能力页就只有一个答案。
//

import Foundation

enum RuntimeCapabilityNames {
    /// manifest 中 Theos 运行时声明的能力。
    static let iosToolchain = "ios.toolchain"
    static let iosCompile = "ios.compile"

    /// manifest 中 OLLVM 运行时声明的能力（三种写法都算）。
    static let ollvmFrontend = "compiler.ollvm.frontend"
    static let ollvmObfuscation = "compiler.ollvm.obfuscation"
    /// 历史 / 兼容写法。
    static let ollvmLegacy = "ios.ollvm"
    static let ollvmShort = "ollvm"

    static let ollvmAliases: Set<String> = [
        ollvmFrontend, ollvmObfuscation, ollvmLegacy, ollvmShort,
    ]

    /// 已安装运行时提供的能力集合。
    @MainActor
    static var installed: Set<String> {
        DeveloperRuntimeManager.shared.installedCapabilities
    }

    /// OLLVM 是否可用。任何别名命中都算。
    @MainActor
    static var ollvmInstalled: Bool {
        !installed.isDisjoint(with: ollvmAliases)
    }

    /// Theos 工具链是否由 Developer Runtime 安装（不代表探测成功）。
    @MainActor
    static var theosInstalled: Bool {
        installed.contains(iosToolchain) || installed.contains(iosCompile)
    }
}
