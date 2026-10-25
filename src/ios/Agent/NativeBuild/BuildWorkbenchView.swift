//
//  BuildWorkbenchView.swift
//  Minis — 编译工作台界面（设置 › Agent 工具 › 编译工作台）
//

#if canImport(UIKit)
import SwiftUI
import UIKit

struct BuildWorkbenchView: View {

    @StateObject private var service = NativeBuildService.shared
    @State private var showPicker = false

    var body: some View {
        Form {
            toolchainSection
            projectSection
            configSection
            actionSection
            if !service.logLines.isEmpty { logSection }
            if let result = service.lastResult, !result.artifacts.isEmpty { artifactSection(result) }
        }
        .navigationTitle(Text(verbatim: "编译工作台"))
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showPicker) {
            FolderPickerView { url in
                url.startAccessingSecurityScopedResource()
                service.projectPath = url.path
                service.persist()
            }
        }
    }

    // MARK: - 工具链

    private var toolchainSection: some View {
        Section {
            HStack {
                Image(systemName: service.toolchainReady ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(service.toolchainReady ? .green : .orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text(service.toolchainReady ? "原生工具链已就绪" : "未找到原生工具链")
                        .font(.subheadline)
                    Text(NativeToolchain.shared.rootPath.isEmpty ? "需要 Theos 运行时（约 224MB）" : NativeToolchain.shared.rootPath)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Button {
                service.refreshToolchain()
            } label: {
                Label("重新检测", systemImage: "arrow.clockwise")
            }
        } header: {
            Text(verbatim: "工具链")
        } footer: {
            Text(verbatim: "原生工具链 = 直接调用设备上的 Theos（clang / ld64 / dpkg-deb），不经过 iSH 的 Linux 模拟层。可复用 MT 智能体已下载的运行时。")
        }
    }

    // MARK: - 工程

    private var projectSection: some View {
        Section {
            Button {
                showPicker = true
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(service.projectPath.isEmpty ? "选择工程目录…" : (service.projectPath as NSString).lastPathComponent)
                            .foregroundStyle(service.projectPath.isEmpty ? Color.accentColor : .primary)
                        if !service.projectPath.isEmpty {
                            Text("\(NativeToolchain.shared.detectKind(service.projectPath).rawValue) · \(service.projectPath)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                    Spacer()
                    Image(systemName: "folder")
                }
            }
        } header: {
            Text(verbatim: "工程")
        }
    }

    // MARK: - 配置

    private var configSection: some View {
        Section {
            Picker("打包方案", selection: Binding(get: { service.scheme },
                                                  set: { service.scheme = $0; service.persist() })) {
                Text(verbatim: "rootless").tag("rootless")
                Text(verbatim: "rootful").tag("rootful")
                Text(verbatim: "roothide").tag("roothide")
            }
            Picker("架构", selection: Binding(get: { service.archs },
                                              set: { service.archs = $0; service.persist() })) {
                Text(verbatim: "arm64").tag("arm64")
                Text(verbatim: "arm64e").tag("arm64e")
                Text(verbatim: "arm64 arm64e").tag("arm64 arm64e")
            }
            Toggle("构建前清理", isOn: Binding(get: { service.cleanBeforeBuild },
                                              set: { service.cleanBeforeBuild = $0; service.persist() }))
            TextField("附加 make 参数", text: Binding(get: { service.extraFlags },
                                                    set: { service.extraFlags = $0; service.persist() }))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        } header: {
            Text(verbatim: "构建配置")
        }
    }

    // MARK: - 操作

    private var actionSection: some View {
        Section {
            if service.running {
                Button(role: .destructive) {
                    service.cancel()
                } label: {
                    Label("终止构建", systemImage: "stop.fill")
                }
            } else {
                Button {
                    service.startBuild()
                } label: {
                    Label("构建 DEB", systemImage: "hammer.fill")
                }
                .disabled(service.projectPath.isEmpty || !service.toolchainReady)
            }
            if let result = service.lastResult {
                Text(result.ok ? "上次构建成功 · \(String(format: "%.1f", result.seconds)) 秒"
                                : "上次构建失败（退出码 \(result.exitCode)）")
                    .font(.caption)
                    .foregroundStyle(result.ok ? Color.green : Color.red)
            }
        } header: {
            Text(verbatim: "构建")
        }
    }

    // MARK: - 日志

    private var logSection: some View {
        Section {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(service.logLines.enumerated()), id: \.offset) { index, line in
                            Text(verbatim: line)
                                .font(.system(size: 10.5, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(index)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .frame(height: 220)
                .onChange(of: service.logLines.count) { newValue in
                    if newValue > 0 { proxy.scrollTo(newValue - 1, anchor: .bottom) }
                }
            }
        } header: {
            HStack {
                Text(verbatim: "日志")
                Spacer()
                Text(verbatim: "\(service.logLines.count) 行")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - 产物

    private func artifactSection(_ result: NativeBuildResult) -> some View {
        Section {
            ForEach(result.artifacts, id: \.self) { path in
                ShareLink(item: URL(fileURLWithPath: path)) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: (path as NSString).lastPathComponent)
                            Text(verbatim: path)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        Image(systemName: "square.and.arrow.up")
                    }
                }
            }
        } header: {
            Text(verbatim: "产物")
        }
    }
}

// MARK: - 目录选择器

struct FolderPickerView: UIViewControllerRepresentable {
    let onPick: (URL) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder], asCopy: false)
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = false
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL) -> Void
        init(onPick: @escaping (URL) -> Void) { self.onPick = onPick }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else { return }
            onPick(url)
        }
    }
}

// MARK: - 设置页入口

extension ToolsSettingsView {
    /// 由 ToolsSettingsView.body 引用，插在 Agent 工具列表末尾。
    @ViewBuilder
    var nativeBuildSection: some View {
        Section {
            NavigationLink {
                BuildWorkbenchView()
            } label: {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: "编译工作台")
                        Text(verbatim: "用原生 Theos 工具链编译 tweak 工程，不经过 iSH")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "hammer.fill")
                }
            }
        } footer: {
            Text(verbatim: "开启后 Agent 也可以用 native_build 工具直接编译设备上的 Theos 工程。")
        }
    }
}

#endif
