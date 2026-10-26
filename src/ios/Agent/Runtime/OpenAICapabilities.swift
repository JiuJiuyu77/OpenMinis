//
//  OpenAICapabilities.swift
//  Minis — OpenAI 能力的 provider
//
//  为什么要单独一个 provider：`CapabilityRegistry` 回答的是“这个构建现在能
//  做什么”。OpenAI 相关的“能力”不在工具链里，而在用户的 Provider 配置里：
//
//      openai.api          有至少一个启用的 OpenAI / Responses API 实例
//      openai.credentials  该实例有可用凭据（API Key 或手动 OAuth token）
//      openai.chat         能发对话请求（= 有实例 + 有凭据）
//      openai.models       至少有一个模型条目可选
//      openai.images       配置了图像生成端点（/v1/images/generations 或兼容）
//
//  这样设置页、插件诊断、Agent 工具预检都能拿到同一份答案，而不是各自去
//  翻 ProviderConfigStore 并得出不同结论。
//
//  probe 必须廉价：只读内存里的 ProviderConfigStore 快照与 Keychain 缓存，
//  不发网络请求、不刷新模型列表。
//

import Foundation

/// OpenAI 家族能力 id。插件/脚本按这些字符串查询，不要改名。
enum OpenAICapabilityID {
    /// 存在一个启用的 OpenAI 实例（含 `openAI` 与 `openAIResponses`）。
    static let api = "openai.api"
    /// 该实例有可用凭据（API Key / 手动 OAuth token / OAuth 会话）。
    static let credentials = "openai.credentials"
    /// 能直接发对话请求。
    static let chat = "openai.chat"
    /// 至少有一个模型条目可选。
    static let models = "openai.models"
    /// 配置了图像生成端点。
    static let images = "openai.images"
}

/// 读取 `ProviderConfigStore` 的 OpenAI 能力提供者。
///
/// `@MainActor` 因为 `ProviderConfigStore` 是主线程隔离的；注册表本身也在
/// 主线程，不需要额外跳线程。
@MainActor
struct OpenAICapabilities: CapabilityProviding {

    var providerIdentifier: String { "openai" }

    var descriptors: [CapabilityDescriptor] {
        [
            CapabilityDescriptor(
                id: OpenAICapabilityID.api,
                displayName: AppLocalized("OpenAI API"),
                kind: .other,
                requires: [],
                summary: AppLocalized("An enabled OpenAI (or Responses API) provider instance is configured.")),
            CapabilityDescriptor(
                id: OpenAICapabilityID.credentials,
                displayName: AppLocalized("OpenAI credentials"),
                kind: .other,
                requires: [OpenAICapabilityID.api],
                summary: AppLocalized("That instance has an API key or a stored OAuth token.")),
            CapabilityDescriptor(
                id: OpenAICapabilityID.chat,
                displayName: AppLocalized("OpenAI chat"),
                kind: .other,
                requires: [OpenAICapabilityID.api, OpenAICapabilityID.credentials],
                summary: AppLocalized("Chat requests can be sent with the configured OpenAI instance.")),
            CapabilityDescriptor(
                id: OpenAICapabilityID.models,
                displayName: AppLocalized("OpenAI models"),
                kind: .other,
                requires: [OpenAICapabilityID.api],
                summary: AppLocalized("At least one model is available for the OpenAI instance.")),
            CapabilityDescriptor(
                id: OpenAICapabilityID.images,
                displayName: AppLocalized("OpenAI image generation"),
                kind: .other,
                requires: [OpenAICapabilityID.credentials],
                summary: AppLocalized("The instance uses an image-capable endpoint.")),
        ]
    }

    func probe(_ id: String) -> CapabilityStatus? {
        switch id {
        case OpenAICapabilityID.api:
            guard Self.enabledInstance() != nil else {
                return .missing(id,
                                reason: AppLocalized("Add and enable an OpenAI provider in Settings → Providers."),
                                provider: providerIdentifier)
            }
            return .ok(id, provider: providerIdentifier)
        case OpenAICapabilityID.credentials:
            guard let instance = Self.enabledInstance() else {
                return .blocked(id,
                                reason: AppLocalized("No OpenAI provider instance is enabled."),
                                provider: providerIdentifier)
            }
            if instance.hasAnyCredential {
                return .ok(id, provider: providerIdentifier)
            }
            return .missing(id,
                            reason: AppLocalized("The OpenAI instance has no API key or OAuth token."),
                            provider: providerIdentifier)
        case OpenAICapabilityID.chat:
            guard let instance = Self.enabledInstance() else {
                return .blocked(id,
                                reason: AppLocalized("No OpenAI provider instance is enabled."),
                                provider: providerIdentifier)
            }
            if instance.hasAnyCredential || instance.allowsEmptyAPIKey {
                return .ok(id, provider: providerIdentifier)
            }
            return .blocked(id,
                            reason: AppLocalized("The OpenAI instance has no usable credential."),
                            provider: providerIdentifier)
        case OpenAICapabilityID.models:
            guard let instance = Self.enabledInstance() else {
                return .blocked(id,
                                reason: AppLocalized("No OpenAI provider instance is enabled."),
                                provider: providerIdentifier)
            }
            let hasEntries = !Self.modelEntries(for: instance).isEmpty
            if hasEntries { return .ok(id, provider: providerIdentifier) }
            return .missing(id,
                            reason: AppLocalized("No model entry belongs to the OpenAI instance yet — refresh its models."),
                            provider: providerIdentifier)
        case OpenAICapabilityID.images:
            guard let instance: ProviderInstance = Self.enabledInstance() else {
                return .blocked(id,
                                reason: AppLocalized("No OpenAI provider instance is enabled."),
                                provider: providerIdentifier)
            }
            // 只要有凭据就算具备图像能力：具体端点（images/generations 还是
            // chat/completions）由 ProviderInstance.imageEndpointMode 运行时决定。
            if instance.hasAnyCredential || instance.allowsEmptyAPIKey {
                return .ok(id, provider: providerIdentifier)
            }
            return .blocked(id,
                            reason: AppLocalized("The OpenAI instance has no usable credential."),
                            provider: providerIdentifier)
        default:
            return nil
        }
    }

    // MARK: - Store access

    /// 第一个启用的 OpenAI 家族实例。`openAI` 优先于 `openAIResponses`，
    /// 因为它是最常见的配置。
    static func enabledInstance() -> ProviderInstance? {
        let instances = ProviderConfigStore.shared.instances.filter {
            $0.isEnabled && ($0.providerType == .openAI || $0.providerType == .openAIResponses)
        }
        return instances.first(where: { $0.providerType == .openAI }) ?? instances.first
    }

    private static func modelEntries(for instance: ProviderInstance) -> [ModelEntry] {
        ProviderConfigStore.shared.config.modelEntries.filter {
            $0.providerInstanceId == instance.id
        }
    }
}
