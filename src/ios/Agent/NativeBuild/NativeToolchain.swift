//
//  NativeToolchain.swift
//  Minis — 原生编译工具链（不依赖 iSH）
//
//  背景：iSH 是为了在 App Store 沙盒里跑 Linux 才引入的模拟层。
//  本文件走另一条路：直接 posix_spawn 真正的 iOS Mach-O 工具链
//  （MT 运行时里的 Theos：clang / ld64 / dpkg-deb / ldid / bash）。
//
//  前提：App 必须带 platform-application / no-sandbox 权限
//  （TrollStore 或越狱安装）。没有权限时 isAvailable 返回 false，
//  上层会回退到 iSH，功能不回归。
//

import Foundation

struct NativeToolchain {

    static let shared = NativeToolchain()

    private static let cacheLock = NSLock()
    private static var cachedTheos: URL?? = nil
    private static var cachedShell: String?? = nil

    /// 工具链根目录（含 makefiles/common.mk 的那一层）。
    var theosRoot: URL? {
        Self.cacheLock.lock()
        defer { Self.cacheLock.unlock() }
        if let cached = Self.cachedTheos { return cached }
        let found = Self.discoverTheos()
        Self.cachedTheos = found
        return found
    }

    /// 实际用来执行脚本的 shell。必须是 App 自带或运行时自带的 bash/sh ——
    /// 原厂 iOS 的 /bin/sh 行为受限，不能依赖。
    var shellPath: String? {
        Self.cacheLock.lock()
        defer { Self.cacheLock.unlock() }
        if let cached = Self.cachedShell { return cached }
        let found = Self.discoverShell()
        Self.cachedShell = found
        return found
    }

    var isAvailable: Bool { theosRoot != nil && shellPath != nil }

    /// 用户点了「重新检测」：清掉探测缓存。
    func resetCache() {
        Self.cacheLock.lock()
        Self.cachedTheos = nil
        Self.cachedShell = nil
        Self.cacheLock.unlock()
        Self.toolLock.lock()
        Self.toolCache.removeAll()
        Self.toolLock.unlock()
    }

    var rootPath: String { theosRoot?.path ?? "" }

    // MARK: - 探测

    /// 候选根目录，按优先级：
    /// 1. App 内置 `NativeToolchain/`（把运行时随包分发时用）
    /// 2. App 容器 `Library/Application Support/NativeToolchain/`
    /// 3. MT 智能体已下载的运行时（与 MT 共用一份，省 224MB）
    static func candidateRoots() -> [URL] {
        var roots: [URL] = []
        roots.append(Bundle.main.bundleURL.appendingPathComponent("NativeToolchain", isDirectory: true))
        if let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            roots.append(support.appendingPathComponent("NativeToolchain", isDirectory: true))
            roots.append(support.appendingPathComponent("CodexApp", isDirectory: true))
        }
        roots.append(URL(fileURLWithPath: "/var/mobile/Library/Application Support/CodexApp"))
        roots.append(URL(fileURLWithPath: "/var/mobile/Library/Application Support/NativeToolchain"))
        return roots
    }

    static func looksLikeTheos(_ url: URL) -> Bool {
        let fm = FileManager.default
        if fm.fileExists(atPath: url.appendingPathComponent("makefiles/common.mk").path) { return true }
        let inner = url.appendingPathComponent("theos", isDirectory: true)
        return fm.fileExists(atPath: inner.appendingPathComponent("makefiles/common.mk").path)
    }

    /// 广度优先扫描（限制深度与节点数，避免在大目录里卡住首屏）。
    static func discoverTheos() -> URL? {
        for root in candidateRoots() {
            if looksLikeTheos(root) {
                let inner = root.appendingPathComponent("theos", isDirectory: true)
                return looksLikeTheos(inner) ? inner : root
            }
            if let hit = bfsTheos(from: root, maxDepth: 6) { return hit }
        }
        return nil
    }

    private static func bfsTheos(from root: URL, maxDepth: Int) -> URL? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: root.path) else { return nil }
        var queue: [(URL, Int)] = [(root, 0)]
        var visited = 0
        let skip: Set<String> = [".git", "node_modules", "packages", "Caches", "tmp", "sdks"]

        while !queue.isEmpty && visited < 3000 {
            let (dir, depth) = queue.removeFirst()
            visited += 1
            if looksLikeTheos(dir) {
                let inner = dir.appendingPathComponent("theos", isDirectory: true)
                return looksLikeTheos(inner) ? inner : dir
            }
            guard depth < maxDepth else { continue }
            let children = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey],
                                                        options: [.skipsHiddenFiles])) ?? []
            for child in children {
                guard (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
                if skip.contains(child.lastPathComponent) { continue }
                queue.append((child, depth + 1))
            }
        }
        return nil
    }

    static func discoverShell() -> String? {
        let fm = FileManager.default
        var candidates: [URL] = []
        candidates.append(Bundle.main.bundleURL.appendingPathComponent("NativeToolchain/bin/bash"))
        candidates.append(Bundle.main.bundleURL.appendingPathComponent("Helpers/bash.real"))
        if let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            candidates.append(support.appendingPathComponent("NativeToolchain/bin/bash"))
        }
        // 运行时里若自带 bash 也可用
        if let theos = discoverTheos() {
            candidates.append(theos.appendingPathComponent("bin/bash"))
            candidates.append(theos.deletingLastPathComponent().appendingPathComponent("Helpers/bash.real"))
        }
        candidates.append(URL(fileURLWithPath: "/var/mobile/Library/Application Support/CodexApp/Helpers/bash.real"))
        candidates.append(URL(fileURLWithPath: "/bin/sh"))
        return candidates.first { fm.isExecutableFile(atPath: $0.path) }?.path
    }

    // MARK: - 环境

    /// 工具链内所有 bin 目录（PATH 前置用）。
    func searchPaths() -> [String] {
        var paths: [String] = []
        let fm = FileManager.default
        if let root = theosRoot {
            for rel in ["bin", "toolchain/bin", "toolchain/usr/bin", "toolchain/linux/iphone/bin",
                        "toolchain/iphone/bin", "libexec/theos/bin"] {
                let p = root.appendingPathComponent(rel).path
                if fm.fileExists(atPath: p) { paths.append(p) }
            }
        }
        // App 自带的 coreutils 替身（tar/cp/mv/mkdir… 都是同一个多合一二进制）
        for rel in ["NativeToolchain/bin", "Helpers", "Helpers/TheosCompat", "Helpers/TheosCoreCompat"] {
            let p = Bundle.main.bundleURL.appendingPathComponent(rel).path
            if fm.fileExists(atPath: p) { paths.append(p) }
        }
        paths.append(contentsOf: ["/usr/bin", "/bin", "/usr/sbin", "/sbin", "/usr/local/bin"])
        return paths
    }

    private static let toolLock = NSLock()
    private static var toolCache: [String: String] = [:]

    /// 运行时内查找可执行文件（供 CA_THEOS_* 使用）。
    func findTool(_ name: String) -> String? {
        Self.toolLock.lock()
        if let hit = Self.toolCache[name] { Self.toolLock.unlock(); return hit }
        Self.toolLock.unlock()
        let found = searchTool(name)
        if let found {
            Self.toolLock.lock()
            Self.toolCache[name] = found
            Self.toolLock.unlock()
        }
        return found
    }

    private func searchTool(_ name: String) -> String? {
        let fm = FileManager.default
        for dir in searchPaths() {
            let p = (dir as NSString).appendingPathComponent(name)
            if fm.isExecutableFile(atPath: p) { return p }
        }
        guard let root = theosRoot else { return nil }
        var queue: [(URL, Int)] = [(root, 0)]
        var visited = 0
        while !queue.isEmpty && visited < 600 {
            let (dir, depth) = queue.removeFirst()
            visited += 1
            let p = dir.appendingPathComponent(name).path
            if fm.isExecutableFile(atPath: p) { return p }
            guard depth < 4 else { continue }
            let children = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey],
                                                        options: [.skipsHiddenFiles])) ?? []
            for child in children {
                if [".git", "share", "man", "include", "sdks"].contains(child.lastPathComponent) { continue }
                if (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    queue.append((child, depth + 1))
                }
            }
        }
        return nil
    }

    /// 构造给子进程的环境。与 MT 的内嵌 Theos 约定保持一致，
    /// makefile 会走 theos-helper 的 forkless 分支。
    func environment(projectPath: String? = nil) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = searchPaths().joined(separator: ":")
        env["HOME"] = NSHomeDirectory()
        env["TMPDIR"] = NSTemporaryDirectory()
        env["LANG"] = "en_US.UTF-8"
        env["LC_ALL"] = "en_US.UTF-8"
        env["TERM"] = "dumb"

        if let root = theosRoot {
            env["THEOS"] = root.path
            env["CA_THEOS_RUNTIME"] = root.path
            env["CA_THEOS_PATH"] = root.path
            env["CA_THEOS_EMBEDDED"] = "1"
            if let sdk = findSDK() { env["SYSROOT"] = sdk; env["CA_THEOS_SDKROOT"] = sdk }
        }
        if let shell = shellPath { env["CA_THEOS_BASH"] = shell }

        let helperCandidates = [Bundle.main.bundleURL.appendingPathComponent("Helpers/theos-helper"),
                                Bundle.main.bundleURL.appendingPathComponent("NativeToolchain/bin/theos-helper")]
        for h in helperCandidates where FileManager.default.isExecutableFile(atPath: h.path) {
            env["CA_THEOS_HELPER"] = h.path
            break
        }
        let tools: [String: String] = ["CA_THEOS_MAKE": "make", "CA_THEOS_CLANG": "clang",
                                       "CA_THEOS_CLANGXX": "clang++", "CA_THEOS_DPKG_DEB": "dpkg-deb",
                                       "CA_THEOS_TAR": "tar", "CA_THEOS_GZIP": "gzip",
                                       "CA_THEOS_XZ": "xz", "CA_THEOS_PERL": "perl"]
        for (key, tool) in tools {
            if let p = findTool(tool) { env[key] = p }
        }
        if let projectPath { env["MINIS_PROJECT"] = projectPath }
        return env
    }

    func findSDK() -> String? {
        let fm = FileManager.default
        guard let root = theosRoot else { return nil }
        for rel in ["sdks", "sdk", "theos/sdks", "toolchain/sdks"] {
            let dir = root.appendingPathComponent(rel, isDirectory: true)
            let names = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
            if let sdk = names.first(where: { $0.hasSuffix(".sdk") }) {
                return dir.appendingPathComponent(sdk).path
            }
        }
        return nil
    }

    // MARK: - 工程识别

    enum ProjectKind: String {
        case theos = "Theos 插件工程"
        case make = "Makefile 工程"
        case xcode = "Xcode 工程"
        case unknown = "未识别"
    }

    func detectKind(_ path: String) -> ProjectKind {
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: path)) ?? []
        let hasMakefile = names.contains { ["Makefile", "makefile", "GNUmakefile"].contains($0) }
        let hasXcode = names.contains { $0.hasSuffix(".xcodeproj") || $0.hasSuffix(".xcworkspace") }
        let hasTweakSource = names.contains { $0.hasSuffix(".x") || $0.hasSuffix(".xm") }
        let hasControl = names.contains("control") || fm.fileExists(atPath: (path as NSString).appendingPathComponent("layout"))
        if hasMakefile && (hasControl || hasTweakSource) { return .theos }
        if hasMakefile { return .make }
        if hasXcode { return .xcode }
        return .unknown
    }

    func artifacts(in projectPath: String) -> [String] {
        let fm = FileManager.default
        let pkg = (projectPath as NSString).appendingPathComponent("packages")
        var out: [String] = []
        for dir in [pkg, projectPath] {
            for name in (try? fm.contentsOfDirectory(atPath: dir)) ?? [] where name.lowercased().hasSuffix(".deb") {
                let full = (dir as NSString).appendingPathComponent(name)
                if !out.contains(full) { out.append(full) }
            }
        }
        return out.sorted { a, b in
            let da = (try? fm.attributesOfItem(atPath: a)[.modificationDate] as? Date) ?? .distantPast
            let db = (try? fm.attributesOfItem(atPath: b)[.modificationDate] as? Date) ?? .distantPast
            return (da ?? .distantPast) > (db ?? .distantPast)
        }
    }
}
