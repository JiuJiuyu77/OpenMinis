//
//  PluginCapabilityBridge.swift
//  Minis — 插件能力桥
//
//  插件可以在自己的 manifest 里声明能力，例如：
//
//      { "id": "acme.lint", "capabilities": [
//          { "id": "plugin.acme.lint", "display_name": "Acme Linter",
//            "kind": "plugin", "requires": ["fs.workspace"],
//            "summary": "Static analysis for Swift sources." } ] }
//
//  这个桥把已加载插件的声明注册进 `CapabilityRegistry`：
//    * 插件加载 → register(pluginID, descriptors:)
//    * 插件卸载 → unregister(pluginID)，能力随之消失
//
//  provider 的 probe 只回答“插件是否仍处于已加载状态”，不尝试在这里执行
//  插件代码——能力是否真的能跑由插件自己的工具在调用时报告。
//

import Foundation

/// 插件在 manifest 中声明的单项能力。
struct PluginCapabilityDeclaration: Codable, Equatable {
    let id: String
    let displayName: String
    let kind: String?
    let requires: [String]?
    let summary: String?

    enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
        case kind
        case requires
        case summary
    }

    var descriptor: CapabilityDescriptor {
        CapabilityDescriptor(
            id: id,
            displayName: displayName,
            kind: CapabilityDescriptor.Kind(rawValue: kind ?? "plugin") ?? .plugin,
            requires: requires ?? [],
            summary: summary)
    }
}

/// 一个已加载插件的 provider：descriptors 来自 manifest，
/// probe 只反映该插件当前是否还在已加载集合里。
@MainActor
final class PluginCapabilityProvider: CapabilityProviding {

    let providerIdentifier: String
    let pluginID: String
    private(set) var descriptors: [CapabilityDescriptor]
    private unowned let bridge: PluginCapabilityBridge

    init(pluginID: String,
         declarations: [PluginCapabilityDeclaration],
         bridge: PluginCapabilityBridge) {
        self.pluginID = pluginID
        self.providerIdentifier = "plugin:\(pluginID)"
        self.descriptors = declarations.map(\.descriptor)
        self.bridge = bridge
    }

    func probe(_ id: String) -> CapabilityStatus? {
        guard descriptors.contains(where: { $0.id == id }) else { return nil }
        if bridge.isLoaded(pluginID) {
            return .ok(id, provider: providerIdentifier)
        }
        return .missing(id,
                        reason: AppLocalized("The plugin that provides this capability is not loaded."),
                        provider: providerIdentifier)
    }

    /// 插件热更新声明时替换（同 id 的 provider 会被注册表整体替换）。
    func update(declarations: [PluginCapabilityDeclaration]) {
        descriptors = declarations.map(\.descriptor)
    }
}

/// 插件能力桥。整个 App 只有一个，注册表通过它增删插件能力。
@MainActor
final class PluginCapabilityBridge {

    static let shared = PluginCapabilityBridge()

    private var loadedPlugins: Set<String> = []
    private var providers: [String: PluginCapabilityProvider] = [:]
    /// 记录每个插件声明了哪些能力，便于卸载时精确 unregister。
    private weak var registry: CapabilityRegistry?

    init() {}

    /// 绑定注册表（启动时调用）。之后所有注册/注销都作用在它上面。
    func attach(to registry: CapabilityRegistry) {
        self.registry = registry
    }

    /// 插件加载完成：把它的能力注册进注册表。
    func pluginDidLoad(id: String, declarations: [PluginCapabilityDeclaration]) {
        loadedPlugins.insert(id)
        guard let registry else { return }
        if let existing = providers[id] {
            // 已有 provider：更新声明后重新注册，保持注册顺序不变。
            existing.update(declarations: declarations)
            registry.register(existing)
        } else {
            let provider = PluginCapabilityProvider(pluginID: id, declarations: declarations, bridge: self)
            providers[id] = provider
            registry.register(provider)
        }
    }

    /// 插件卸载 / 禁用：撤销它贡献的全部能力。
    func pluginDidUnload(id: String) {
        loadedPlugins.remove(id)
        providers.removeValue(forKey: id)
        registry?.unregister(providerIdentifier: "plugin:\(id)")
    }

    func isLoaded(_ id: String) -> Bool { loadedPlugins.contains(id) }

    var loadedPluginIDs: [String] { Array(loadedPlugins) }

    /// 已加载插件贡献的能力 id（诊断用）。
    var contributedCapabilityIDs: [String] {
        providers.values.flatMap { $0.descriptors.map(\.id) }
    }
}
