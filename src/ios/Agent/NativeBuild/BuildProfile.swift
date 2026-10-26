//
//  BuildProfile.swift
//  Minis — 可复用的编译配置（模型/项目维度的编译预设）
//
//  为什么单独一个文件：`NativeBuildService` 里的 scheme / archs / 混淆强度 /
//  保护开关 / 输出开关 是十几个各自独立的 @Published，换项目或换模型时要重新
//  勾一遍，很容易把「上次给别的模型开的 paranoid 混淆」带过去。这里把它们做
//  成一份可命名的快照：存下来、命名、一键套用。
//
//  注意：配置只做快照与套用，不复制工程路径（projectPath 属于当前工作区，
//  套用别的项目的路径只会让人莫名其妙）。
//

import Foundation
import SwiftUI

/// 一套可命名的编译配置快照。
struct BuildProfile: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var scheme: String
    var archs: String
    var obfuscation: BuildObfuscation
    var stripSymbols: Bool
    var hideSymbols: Bool
    var encryptStrings: Bool
    var cleanBeforeBuild: Bool
    var packageOnly: Bool
    var incremental: Bool
    var jobs: Int
    var extraFlags: String
    var createdAt: Date

    init(id: UUID = UUID(),
         name: String,
         scheme: String,
         archs: String,
         obfuscation: BuildObfuscation,
         stripSymbols: Bool,
         hideSymbols: Bool,
         encryptStrings: Bool,
         cleanBeforeBuild: Bool,
         packageOnly: Bool,
         incremental: Bool,
         jobs: Int,
         extraFlags: String,
         createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.scheme = scheme
        self.archs = archs
        self.obfuscation = obfuscation
        self.stripSymbols = stripSymbols
        self.hideSymbols = hideSymbols
        self.encryptStrings = encryptStrings
        self.cleanBeforeBuild = cleanBeforeBuild
        self.packageOnly = packageOnly
        self.incremental = incremental
        self.jobs = jobs
        self.extraFlags = extraFlags
        self.createdAt = createdAt
    }

    /// 一行摘要，列表里直接看得到这套配置到底开了什么。
    var summary: String {
        var parts: [String] = []
        parts.append(obfuscation.rawValue)
        if stripSymbols { parts.append("strip") }
        if hideSymbols { parts.append("hidden-sym") }
        if encryptStrings { parts.append("sobf") }
        parts.append(packageOnly ? "pack-only" : "build")
        if incremental { parts.append("incremental") }
        if jobs > 1 { parts.append("jobs=\(jobs)") }
        return parts.joined(separator: " · ")
    }

    /// 混淆强度是否会对产物产生实质影响（用于界面提示）。
    var changesArtifact: Bool {
        obfuscation != .off || stripSymbols || hideSymbols || encryptStrings
    }
}

/// 配置仓。UserDefaults 里存一份 JSON，够用且不引入新的存储层依赖。
@MainActor
final class BuildProfileStore: ObservableObject {

    static let shared = BuildProfileStore()

    @Published private(set) var profiles: [BuildProfile] = []
    @Published private(set) var activeProfileID: UUID?

    private let profilesKey = "nativebuild.profiles.v1"
    private let activeKey = "nativebuild.profiles.activeID"

    private init() {
        load()
    }

    // MARK: - 持久化

    private func load() {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: profilesKey),
           let decoded = try? JSONDecoder().decode([BuildProfile].self, from: data) {
            profiles = decoded
        }
        if let raw = defaults.string(forKey: activeKey), let id = UUID(uuidString: raw) {
            activeProfileID = id
        }
    }

    private func persist() {
        let defaults = UserDefaults.standard
        if let data = try? JSONEncoder().encode(profiles) {
            defaults.set(data, forKey: profilesKey)
        }
        defaults.set(activeProfileID?.uuidString, forKey: activeKey)
    }

    // MARK: - 编辑

    /// 把编译工作台当前的设置存成一套配置。
    @discardableResult
    func saveCurrent(named rawName: String) -> BuildProfile {
        let service = NativeBuildService.shared
        let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = trimmed.isEmpty ? "配置 \(profiles.count + 1)" : trimmed
        let profile = BuildProfile(name: name,
                                   scheme: service.scheme,
                                   archs: service.archs,
                                   obfuscation: service.obfuscation,
                                   stripSymbols: service.stripSymbols,
                                   hideSymbols: service.hideSymbols,
                                   encryptStrings: service.encryptStrings,
                                   cleanBeforeBuild: service.cleanBeforeBuild,
                                   packageOnly: service.packageOnly,
                                   incremental: service.incremental,
                                   jobs: service.jobs,
                                   extraFlags: service.extraFlags)
        profiles.append(profile)
        activeProfileID = profile.id
        persist()
        return profile
    }

    /// 把一套配置套回编译工作台（不碰 projectPath）。
    func apply(_ profile: BuildProfile) {
        let service = NativeBuildService.shared
        service.scheme = profile.scheme
        service.archs = profile.archs
        service.obfuscation = profile.obfuscation
        service.stripSymbols = profile.stripSymbols
        service.hideSymbols = profile.hideSymbols
        service.encryptStrings = profile.encryptStrings
        service.cleanBeforeBuild = profile.cleanBeforeBuild
        service.packageOnly = profile.packageOnly
        service.incremental = profile.incremental
        service.jobs = profile.jobs
        service.extraFlags = profile.extraFlags
        service.persist()
        activeProfileID = profile.id
        persist()
    }

    func rename(_ id: UUID, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let index = profiles.firstIndex(where: { $0.id == id }) else { return }
        profiles[index].name = trimmed
        persist()
    }

    func remove(_ id: UUID) {
        profiles.removeAll { $0.id == id }
        if activeProfileID == id { activeProfileID = nil }
        persist()
    }

    /// 当前设置是否与某套配置一致（用于显示「已套用」而不是只记 id）。
    func matchesCurrentSettings(_ profile: BuildProfile) -> Bool {
        let service = NativeBuildService.shared
        return profile.scheme == service.scheme
            && profile.archs == service.archs
            && profile.obfuscation == service.obfuscation
            && profile.stripSymbols == service.stripSymbols
            && profile.hideSymbols == service.hideSymbols
            && profile.encryptStrings == service.encryptStrings
            && profile.cleanBeforeBuild == service.cleanBeforeBuild
            && profile.packageOnly == service.packageOnly
            && profile.incremental == service.incremental
            && profile.jobs == service.jobs
            && profile.extraFlags == service.extraFlags
    }
}
