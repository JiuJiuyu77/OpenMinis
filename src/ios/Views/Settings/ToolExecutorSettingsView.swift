import SwiftUI

/// Settings → 执行器（Executor）。
///
/// 三个开关：
///   1. 默认执行器：自动 / 沙箱（iSH）/ 原生 Runtime
///   2. 优先使用自定义 Runtime（Developer Runtime 装的那份工具链）
///   3. 沙箱模式（强制只走 iSH，等价于关闭一切原生执行）
///
/// 外加「能力」只读区块：直接问 CapabilityRegistry，展示每项能力当前是否
/// 可用以及不可用的原因——避免设置页说“已安装”、实际调用却失败。
struct ToolExecutorSettingsView: View {

    @ObservedObject private var preference = ToolExecutorPreference.shared
    @ObservedObject private var capabilities = CapabilityRegistry.shared

    var body: some View {
        Form {
            Section {
                Picker("Default executor", selection: $preference.mode) {
                    ForEach(ToolExecutorMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } header: {
                Text("Default executor")
            } footer: {
                Text(preference.mode.explanation)
            }

            Section {
                Toggle(isOn: $preference.sandboxMode) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Sandbox mode")
                        Text("Keep every command inside the iSH Alpine sandbox.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                Toggle(isOn: $preference.preferCustomRuntime) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Prefer custom runtime")
                        Text("Use the toolchain installed from Developer Runtime instead of the shared copy.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .disabled(preference.sandboxMode)
            } header: {
                Text("Native execution")
            } footer: {
                Text("Sandbox mode overrides the executor choice. Native execution needs TrollStore or a jailbreak; in an App Store build everything falls back to iSH.")
            }

            Section {
                LabeledContent("Effective executor", value: preference.resolvedExecutor.displayName)
                if preference.sandboxMode {
                    Label("Sandbox mode is on — native execution is disabled.", systemImage: "lock.shield")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Status")
            }

            Section {
                ForEach(capabilities.report(), id: \.id) { status in
                    CapabilityRow(status: status)
                }
            } header: {
                HStack {
                    Text("Capabilities")
                    Spacer()
                    Button {
                        capabilities.refresh()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(Text("Refresh"))
                }
            } footer: {
                Text("Capabilities come from the app and from installed plugins. A plugin's capabilities disappear when it is unloaded.")
            }
        }
        .navigationTitle("Executor")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { capabilities.registerBuiltinsIfNeeded() }
    }
}

private struct CapabilityRow: View {
    let status: CapabilityStatus

    private var symbol: String {
        switch status.state {
        case .available: return "checkmark.circle.fill"
        case .blocked: return "exclamationmark.circle.fill"
        case .unavailable: return "xmark.circle.fill"
        }
    }

    private var tint: Color {
        switch status.state {
        case .available: return .green
        case .blocked: return .orange
        case .unavailable: return .secondary
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(displayName)
                if let reason = status.reason {
                    Text(reason)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
    }

    /// 优先用内建能力的人类可读名；插件能力回落到 id。
    /// `@MainActor`：`CapabilityRegistry` 是主线程隔离的，`body` 也在主线程，
    /// 但计算属性本身默认 nonisolated，直接调用会触发 Swift 6 的并发诊断。
    @MainActor
    private var displayName: String {
        CapabilityRegistry.shared.descriptor(for: status.id)?.displayName ?? status.id
    }
}
