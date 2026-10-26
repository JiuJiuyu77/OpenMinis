//
//  PluginManagementView.swift
//  Minis — 插件管理（Plugin Management）
//
//  「Plugin Management」是 CodexApp 官方精选目录（openai-curated-remote）里
//  的一类插件管家插件：目录浏览 + 安装/启用/停用 + 来源校验。本页把它做成
//  设置里的一个独立页面，数据来自两个互不替代的来源：
//
//    * CuratedPluginCatalog —— 远端精选目录，回答「作者提供了什么」；
//    * PluginManifestStore  —— 本机扫描的 manifest，回答「这台设备装了什么」。
//
//  只有后者能让能力真正生效；前者只是可选清单。界面把两者并排显示，避免
//  「目录里有」被误读成「已经启用」。
//

import SwiftUI

struct PluginManagementView: View {

    @ObservedObject private var catalog = CuratedPluginCatalog.shared
    @ObservedObject private var store = PluginManifestStore.shared
    @State private var catalogURLInput = CuratedPluginCatalog.shared.catalogURL
    @State private var pendingError: String?
    @State private var showInstallPicker = false
    @State private var pendingInstallID = ""

    var body: some View {
        Form {
            sourceSection
            installedSection
            catalogSection
        }
        .navigationTitle(Text(verbatim: "插件管理"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    Task { await catalog.refresh(); store.reload() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(catalog.isLoading)
            }
        }
        .onAppear {
            Task { await catalog.loadIfNeeded() }
            store.installBundledExamplesIfNeeded()
            store.reload()
        }
        .sheet(isPresented: $showInstallPicker) {
            ArchivePickerView { url in
                install(url, id: pendingInstallID)
            }
        }
        .alert("Plugin", isPresented: Binding(get: { pendingError != nil },
                                              set: { if !$0 { pendingError = nil } })) {
            Button("OK", role: .cancel) { pendingError = nil }
        } message: {
            Text(verbatim: pendingError ?? "")
        }
    }

    // MARK: - 目录来源

    private var sourceSection: some View {
        Section {
            LabeledContent("Catalog", value: catalog.sourceName ?? "—")
            if let updated = catalog.updatedAt {
                LabeledContent("Updated", value: updated)
            }
            TextField("Catalog URL", text: $catalogURLInput)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.system(size: 11, design: .monospaced))
            HStack {
                Button("Apply and refresh") {
                    catalog.setCatalogURL(catalogURLInput)
                    Task { await catalog.refresh() }
                }
                .disabled(catalogURLInput.trimmingCharacters(in: .whitespaces).isEmpty)
                Button("Reset", role: .destructive) {
                    catalog.setCatalogURL("")
                    catalogURLInput = catalog.catalogURL
                    Task { await catalog.refresh() }
                }
                .font(.footnote)
            }
            if catalog.isLoading {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Refreshing…").font(.footnote).foregroundStyle(.secondary)
                }
            }
            if let error = catalog.lastError {
                Text(verbatim: error)
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        } header: {
            Text(verbatim: "精选目录")
        } footer: {
            Text(verbatim: "精选目录只描述「作者提供了什么」。装没装、开没开，以下面「本机已安装」为准。")
        }
    }

    // MARK: - 本机已安装

    private var installedSection: some View {
        Section {
            if store.manifests.isEmpty {
                Text("No plugins installed.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(store.manifests) { manifest in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(verbatim: manifest.displayName)
                                Text(verbatim: "\(manifest.id) · \(manifest.version ?? "—")")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Toggle("", isOn: Binding(
                                get: { manifest.isEnabled },
                                set: { store.setEnabled($0, pluginID: manifest.id) }))
                                .labelsHidden()
                        }
                        let caps = manifest.capabilities ?? []
                        if !caps.isEmpty {
                            Text(verbatim: caps.map(\.id).joined(separator: " · "))
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                }
            }
            Button {
                pendingInstallID = ""
                showInstallPicker = true
            } label: {
                Label("Install from file (zip / tar.gz)", systemImage: "square.and.arrow.down")
            }
            Button {
                store.reload()
            } label: {
                Label("Rescan", systemImage: "arrow.triangle.2.circlepath")
            }
            if let error = store.lastError {
                Text(verbatim: error).font(.caption2).foregroundStyle(.orange)
            }
        } header: {
            Text(verbatim: "本机已安装")
        } footer: {
            Text(verbatim: "插件清单位于 MinisConfig/plugins/<id>/manifest.json。停用后它声明的能力会立即从能力列表移除。")
        }
    }

    // MARK: - 精选目录条目

    private var catalogSection: some View {
        Section {
            if catalog.entries.isEmpty {
                Text(catalog.isLoading ? "Loading…" : "No catalog entries.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(catalog.groups, id: \.title) { group in
                    DisclosureGroup {
                        ForEach(group.items) { entry in
                            catalogRow(entry)
                        }
                    } label: {
                        HStack {
                            Text(verbatim: group.title)
                            Spacer()
                            Text(verbatim: "\(group.items.count)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        } header: {
            Text(verbatim: "目录条目")
        } footer: {
            Text(verbatim: "「插件管家」是精选目录里负责浏览与管理其它插件的条目；它本身不执行功能，功能来自被它管理的插件。")
        }
    }

    @ViewBuilder
    private func catalogRow(_ entry: CuratedPluginEntry) -> some View {
        let installed = catalog.isInstalled(entry)
        let enabled = catalog.isEnabled(entry)
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: entry.displayName)
                    Text(verbatim: "\(entry.id) · \(entry.version ?? "—")")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if installed {
                    Text(verbatim: enabled ? AppLocalized("Enabled") : AppLocalized("Disabled"))
                        .font(.caption2)
                        .foregroundStyle(enabled ? Color.green : .secondary)
                }
            }
            if let summary = entry.summary {
                Text(verbatim: summary)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if let caps = entry.capabilities, !caps.isEmpty {
                Text(verbatim: caps.joined(separator: " · "))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            if !installed {
                if let url = entry.downloadURL, !url.isEmpty {
                    Text(verbatim: url)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .textSelection(.enabled)
                    Button {
                        pendingInstallID = entry.id
                        showInstallPicker = true
                    } label: {
                        Label("Install from downloaded archive", systemImage: "square.and.arrow.down")
                            .font(.caption)
                    }
                } else {
                    Text(verbatim: "Not installed — download it yourself, then use Install from file.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: - 安装

    private func install(_ url: URL, id: String) {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        // Derive the plugin id from the archive name when the caller has none.
        var pluginID = id
        if pluginID.isEmpty {
            pluginID = url.deletingPathExtension().lastPathComponent
                .replacingOccurrences(of: ".tar", with: "")
        }
        if store.installArchive(url, pluginID: pluginID) {
            pendingError = nil
        } else {
            pendingError = store.lastError ?? "Install failed"
        }
    }
}
