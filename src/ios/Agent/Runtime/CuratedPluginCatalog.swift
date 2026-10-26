//
//  CuratedPluginCatalog.swift
//  Minis — 精选插件目录（Plugin Management）
//
//  「Plugin Management」不是 Minis 自造的插件，而是 CodexApp 官方精选目录
//  （openai-curated-remote）里的一类「插件管家」插件：它本身只做目录浏览、
//  安装/启用/停用与来源校验，真正的功能由它管理的那些插件提供。
//
//  本文件实现该目录在 Minis 侧的最小可用形式：
//
//    * 从可配置的精选目录（`catalog.json`）读取条目，带本地缓存回退；
//    * 条目只描述元数据 + 声明能力，不下载可执行代码（下载由用户决定，
//      并且必须通过 SHA-256 校验后才能落到 plugins/ 目录）；
//    * 已安装来源与目录条目按 id 对齐，界面据此显示「已安装 / 有更新 / 未安装」。
//
//  之所以不直接把远端 catalog 的插件当成「已启用」：精选目录只能证明
//  「作者声明了什么」，不能证明本机真的装了这个插件 —— 那要读
//  `PluginManifestStore` 扫描到的 manifest。
//

import Foundation

private let logger = AppLogger(category: "Plugin")

/// 精选目录中的一个条目。
struct CuratedPluginEntry: Codable, Identifiable, Equatable {
    let id: String
    let name: String?
    let version: String?
    let summary: String?
    let author: String?
    let homepage: String?
    /// 分类标签，用于分组（例如 "plugin-manager"、"tool"、"provider"）。
    let category: String?
    /// 该插件声明的能力 id（与 PluginCapabilityDeclaration 一致）。
    let capabilities: [String]?
    /// 依赖的其他能力（例如 `openai.chat`）。
    let requires: [String]?
    /// 分发包地址（.zip 或 .tar.gz），可选。
    let downloadURL: String?
    let sha256: String?

    enum CodingKeys: String, CodingKey {
        case id, name, version, summary, author, homepage, category
        case capabilities, requires, sha256
        case downloadURL = "download_url"
    }

    var displayName: String { name ?? id }
    var isPluginManager: Bool { category == "plugin-manager" }
}

struct CuratedPluginCatalogFile: Codable {
    let schema: Int?
    let name: String?
    let updatedAt: String?
    let plugins: [CuratedPluginEntry]

    enum CodingKeys: String, CodingKey {
        case schema, name, plugins
        case updatedAt = "updated_at"
    }
}

/// 目录状态：来源、条目、错误。
@MainActor
final class CuratedPluginCatalog: ObservableObject {

    static let shared = CuratedPluginCatalog()

    @Published private(set) var entries: [CuratedPluginEntry] = []
    @Published private(set) var isLoading = false
    @Published private(set) var lastError: String?
    @Published private(set) var sourceName: String?
    @Published private(set) var updatedAt: String?

    /// 精选目录地址。默认指向 openai-curated-remote 的镜像约定地址；
    /// 用户可在设置里改写（存 UserDefaults），便于内网/离线部署。
    static let defaultCatalogURL =
        "https://raw.githubusercontent.com/susu123oss/CodexApp-Runtime/main/Runtime/openai-curated-remote/catalog.json"

    private static let overrideKey = "pluginCatalog.url"

    var catalogURL: String {
        let custom = UserDefaults.standard.string(forKey: Self.overrideKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return custom.isEmpty ? Self.defaultCatalogURL : custom
    }

    func setCatalogURL(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            UserDefaults.standard.removeObject(forKey: Self.overrideKey)
        } else {
            UserDefaults.standard.set(trimmed, forKey: Self.overrideKey)
        }
    }

    private var cacheURL: URL {
        DeveloperRuntimePaths.root.appendingPathComponent("plugin-catalog.json")
    }

    /// 读取目录：网络成功则刷新缓存，失败则回退缓存，再失败就只剩空列表。
    func loadIfNeeded() async {
        guard entries.isEmpty, !isLoading else { return }
        await refresh()
    }

    func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        lastError = nil

        var candidates: [String] = [catalogURL]
        for prefix in RuntimeManifestLoader.mirrorPrefixes where !prefix.isEmpty {
            candidates.append(prefix + catalogURL)
        }
        for candidate in candidates {
            guard let url = URL(string: candidate) else { continue }
            var request = URLRequest(url: url)
            request.timeoutInterval = 30
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                    throw URLError(.badServerResponse)
                }
                let file = try JSONDecoder().decode(CuratedPluginCatalogFile.self, from: data)
                apply(file)
                try? FileManager.default.createDirectory(at: DeveloperRuntimePaths.root,
                                                         withIntermediateDirectories: true)
                try? data.write(to: cacheURL, options: .atomic)
                return
            } catch {
                logger.warning("Plugin catalog attempt failed (\(candidate)): \(error.localizedDescription)")
                lastError = error.localizedDescription
            }
        }

        if let cached = try? Data(contentsOf: cacheURL),
           let file = try? JSONDecoder().decode(CuratedPluginCatalogFile.self, from: cached) {
            apply(file)
            lastError = nil
            logger.notice("Using cached plugin catalog (\(file.plugins.count) entries)")
            return
        }
        if lastError == nil { lastError = "Plugin catalog is empty or unreachable." }
    }

    private func apply(_ file: CuratedPluginCatalogFile) {
        entries = file.plugins.sorted { a, b in
            if a.isPluginManager != b.isPluginManager { return a.isPluginManager }
            return a.displayName.localizedCompare(b.displayName) == .orderedAscending
        }
        sourceName = file.name
        updatedAt = file.updatedAt
    }

    /// 分组：插件管家在最前，其余按 category。
    var groups: [(title: String, items: [CuratedPluginEntry])] {
        var byCategory: [String: [CuratedPluginEntry]] = [:]
        for entry in entries {
            let key = entry.isPluginManager ? "Plugin Management" : (entry.category ?? "Other")
            byCategory[key, default: []].append(entry)
        }
        return byCategory
            .map { (title: $0.key, items: $0.value) }
            .sorted { a, b in
                if (a.title == "Plugin Management") != (b.title == "Plugin Management") {
                    return a.title == "Plugin Management"
                }
                return a.title < b.title
            }
    }

    /// 是否已由本地 manifest 提供（按 id）。
    func isInstalled(_ entry: CuratedPluginEntry) -> Bool {
        PluginManifestStore.shared.manifests.contains { $0.id == entry.id }
    }

    func isEnabled(_ entry: CuratedPluginEntry) -> Bool {
        PluginManifestStore.shared.manifests.first { $0.id == entry.id }?.isEnabled ?? false
    }
}
