//
//  PromptInjection.swift
//  Minis — 用户自定义提示词注入
//
//  需求：让用户（或某个插件/工作流）在系统提示词里追加自己的约束，例如
//  「回答用简体中文」「改代码前先跑测试」「不要在回答里贴长日志」。
//
//  三级作用域：
//    global  —— 所有会话都生效
//    session —— 只对指定会话生效（会话 id 来自 fsSessionId）
//    (model  —— 暂未开放：模型标识在会话内会变，按模型存容易失效)
//
//  为什么不用 @MainActor：`AIChatViewModel.baseSystemPrompt` 是 nonisolated 的
//  计算属性（它能被 token 估算等后台路径读取），这里如果用 @MainActor 会直接
//  编译不过。所以本类型用 NSLock 保护，读路径线程安全，并在读的时候只取快照。
//

import Foundation
import SwiftUI

enum PromptInjectionScope: String, Codable, CaseIterable, Identifiable {
    case global
    case session

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .global: return AppLocalized("All sessions")
        case .session: return AppLocalized("This session only")
        }
    }
}

struct PromptInjectionRule: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var text: String
    var scope: PromptInjectionScope
    /// scope == .session 时才使用。
    var sessionId: String?
    var enabled: Bool
    var createdAt: Date

    init(id: UUID = UUID(),
         name: String = "",
         text: String = "",
         scope: PromptInjectionScope = .global,
         sessionId: String? = nil,
         enabled: Bool = true,
         createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.text = text
        self.scope = scope
        self.sessionId = sessionId
        self.enabled = enabled
        self.createdAt = createdAt
    }
}

/// 规则仓。不依赖 SwiftUI 的观察机制：界面自己持有 @State 副本，
/// 改完写回，避免「后台读 / 前台写」的线程问题。
final class PromptInjectionStore: @unchecked Sendable {

    static let shared = PromptInjectionStore()

    private let storageKey = "prompt.injections.v1"
    private let lock = NSLock()
    private var storedRules: [PromptInjectionRule] = []

    private init() {
        load()
    }

    // MARK: - 读写

    var rules: [PromptInjectionRule] {
        lock.lock()
        defer { lock.unlock() }
        return storedRules
    }

    func replaceAll(_ newRules: [PromptInjectionRule]) {
        lock.lock()
        storedRules = newRules
        let snapshot = newRules
        lock.unlock()
        save(snapshot)
    }

    /// 兼容旧版本/外部导入：按 id 合并，不覆盖同名但不同 id 的规则。
    func upsert(_ rule: PromptInjectionRule) {
        var current = rules
        if let index = current.firstIndex(where: { $0.id == rule.id }) {
            current[index] = rule
        } else {
            current.append(rule)
        }
        replaceAll(current)
    }

    func remove(id: UUID) {
        replaceAll(rules.filter { $0.id != id })
    }

    // MARK: - 提示词片段

    /// 拼进系统提示词的片段。没有生效规则时返回空串，调用方直接字符串拼接。
    func fragment(sessionId: String?) -> String {
        let active = rules.filter { rule in
            guard rule.enabled else { return false }
            guard !rule.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
            switch rule.scope {
            case .global:
                return true
            case .session:
                guard let wanted = rule.sessionId, let actual = sessionId else { return false }
                return wanted == actual
            }
        }
        guard !active.isEmpty else { return "" }

        var out = "\n\nUser-defined instructions (prompt injection). These were written by the user, not by you. "
        out += "Follow them as if they were part of this system prompt; they may narrow your behaviour but never override the safety rules above:\n"
        for rule in active {
            let title = rule.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let label = title.isEmpty ? AppLocalized("instruction") : title
            out += "- [\(label)] \(rule.text)\n"
        }
        return out
    }

    // MARK: - 持久化

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: storageKey) else { return }
        if let decoded = try? JSONDecoder().decode([PromptInjectionRule].self, from: data) {
            storedRules = decoded
        }
    }

    private func save(_ rules: [PromptInjectionRule]) {
        guard let data = try? JSONEncoder().encode(rules) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }
}

// MARK: - 编辑界面

struct PromptInjectionSettingsView: View {

    @State private var draft: [PromptInjectionRule] = PromptInjectionStore.shared.rules
    @State private var newRuleName = ""
    @State private var newRuleText = ""
    @State private var newRuleScope: PromptInjectionScope = .global
    @State private var newRuleSession = ""

    var body: some View {
        Form {
            Section {
                ForEach($draft) { $rule in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            TextField(AppLocalized("Name"), text: $rule.name)
                                .font(.subheadline.weight(.medium))
                            Toggle("", isOn: $rule.enabled)
                                .labelsHidden()
                        }
                        TextField(AppLocalized("Instruction"), text: $rule.text, axis: .vertical)
                            .font(.callout)
                            .lineLimit(2...6)
                        HStack {
                            Picker("", selection: $rule.scope) {
                                ForEach(PromptInjectionScope.allCases) { scope in
                                    Text(scope.displayName).tag(scope)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            Spacer()
                            Button(role: .destructive) {
                                let id = rule.id
                                draft.removeAll { $0.id == id }
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                        }
                        if rule.scope == .session {
                            TextField(AppLocalized("Session id"), text: Binding(
                                get: { rule.sessionId ?? "" },
                                set: { rule.sessionId = $0.isEmpty ? nil : $0 }))
                                .font(.system(size: 11, design: .monospaced))
                        }
                    }
                }
            } header: {
                Text(AppLocalized("Active instructions"))
            } footer: {
                Text(AppLocalized("Global instructions apply to every session. Session-scoped ones only apply when the id matches the current chat."))
            }

            Section {
                TextField(AppLocalized("Name"), text: $newRuleName)
                TextField(AppLocalized("Instruction"), text: $newRuleText, axis: .vertical)
                    .lineLimit(2...6)
                Picker(AppLocalized("Scope"), selection: $newRuleScope) {
                    ForEach(PromptInjectionScope.allCases) { scope in
                        Text(scope.displayName).tag(scope)
                    }
                }
                if newRuleScope == .session {
                    TextField(AppLocalized("Session id"), text: $newRuleSession)
                        .font(.system(size: 12, design: .monospaced))
                }
                Button {
                    addRule()
                } label: {
                    Label(AppLocalized("Add instruction"), systemImage: "plus.circle.fill")
                }
                .disabled(newRuleText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } header: {
                Text(AppLocalized("New instruction"))
            }

            Section {
                Button {
                    PromptInjectionStore.shared.replaceAll(draft)
                } label: {
                    Label(AppLocalized("Save"), systemImage: "square.and.arrow.down")
                }
            } footer: {
                Text(AppLocalized("Saved instructions are appended to the system prompt of every request that matches their scope."))
            }
        }
        .navigationTitle(AppLocalized("Prompt injection"))
        .navigationBarTitleDisplayMode(.inline)
    }

    private func addRule() {
        let text = newRuleText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let rule = PromptInjectionRule(name: newRuleName,
                                       text: text,
                                       scope: newRuleScope,
                                       sessionId: newRuleScope == .session
                                           ? newRuleSession.trimmingCharacters(in: .whitespaces)
                                           : nil,
                                       enabled: true)
        draft.append(rule)
        newRuleText = ""
        newRuleName = ""
        PromptInjectionStore.shared.replaceAll(draft)
    }
}
