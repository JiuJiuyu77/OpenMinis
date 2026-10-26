//
//  ProjectImporter.swift
//  Minis — 手动上传工程（.zip / .tar.gz / 单个目录）
//
//  为什么要它：iOS 没有「选择文件夹」以外的文件系统访问方式，而用户手里的
//  Theos 工程往往是一个压缩包（从 GitHub 下载的 zip，或 `tar czf` 出来的包）。
//  旧版本只接受「已有目录」，于是用户必须先去别的 App 解压、再搬进 Minis 的
//  可见目录。这里直接在 Minis 内解包到工作区，并把解包后的路径回填给
//  编译工作台。
//

import Foundation

private let logger = AppLogger(category: "Build")

enum ProjectImporter {

    enum ImportError: LocalizedError {
        case unsupported(String)
        case emptyArchive
        case multipleRoots([String])
        case noMakefile(String)
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .unsupported(let ext):
                return "Unsupported archive type .\(ext) — use .zip, .tar.gz, .tgz or .tar"
            case .emptyArchive: return "The archive contains no files"
            case .multipleRoots(let names):
                return "The archive has no single top-level project directory (\(names.prefix(4).joined(separator: ", ")))"
            case .noMakefile(let dir): return "No Theos Makefile found in \(dir)"
            case .failed(let reason): return "Import failed: \(reason)"
            }
        }
    }

    struct Outcome {
        let projectPath: String
        let topLevel: String
        let fileCount: Int
        let hadMakefile: Bool
    }

    /// Where imported projects land: `Application Support/MinisProjects/<name>`.
    static var importsRoot: URL? {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                                     in: .userDomainMask).first else { return nil }
        return support.appendingPathComponent("MinisProjects", isDirectory: true)
    }

    /// Import `archive` and return the directory to hand to the build service.
    ///
    /// - Parameter preferredName: used for the destination folder; defaults to
    ///   the archive's file name.
    static func importArchive(_ archive: URL,
                              preferredName: String? = nil,
                              onLog: @escaping (String) -> Void = { _ in }) throws -> Outcome {
        guard let root = importsRoot else {
            throw ImportError.failed("Application Support is not available")
        }
        let ext = archive.pathExtension.lowercased()
        let isZip = ext == "zip"
        let isTarGz = ["gz", "tgz", "tar"].contains(ext)
        guard isZip || isTarGz else { throw ImportError.unsupported(ext) }

        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)

        let baseName = (preferredName?.isEmpty == false ? preferredName! :
            archive.deletingPathExtension().lastPathComponent)
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "")
        let destination = root.appendingPathComponent("\(baseName)-\(stamp)", isDirectory: true)

        onLog("▸ 解包 \(archive.lastPathComponent)…")
        do {
            if isZip {
                try BackupZipExtractor.extract(archive, to: destination)
            } else if archive.lastPathComponent.lowercased().hasSuffix(".tar") {
                try RuntimeTarGzExtractor.extractPlainTar(archive, to: destination)
            } else {
                try RuntimeTarGzExtractor.extract(archive, to: destination)
            }
        } catch {
            try? fm.removeItem(at: destination)
            throw ImportError.failed(error.localizedDescription)
        }

        let entries = (try? fm.contentsOfDirectory(at: destination,
                                                   includingPropertiesForKeys: [.isDirectoryKey],
                                                   options: [.skipsHiddenFiles])) ?? []
        let dirs = entries.filter {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }
        guard !entries.isEmpty else {
            try? fm.removeItem(at: destination)
            throw ImportError.emptyArchive
        }

        // One top-level directory is the normal shape (`MyTweak-1.2/…`); peel it
        // so the build runs where the Makefile actually is. Loose files at the
        // root are also accepted — some projects are exported flat.
        var projectDir = destination
        if dirs.count == 1, entries.count == 1 {
            projectDir = dirs[0]
        }

        let makefiles = ["Makefile", "makefile", "GNUmakefile"]
        let hadMakefile = makefiles.contains {
            fm.fileExists(atPath: projectDir.appendingPathComponent($0).path)
        }
        let fileCount = countFiles(in: projectDir)
        onLog("▸ 已导入 \(fileCount) 个文件 → \(projectDir.path)")
        if !hadMakefile {
            onLog("⚠️ 未找到 Makefile：这个目录可能不是 Theos 工程根，或需要再进一层子目录。")
        }
        logger.notice("Imported project \(projectDir.lastPathComponent) files=\(fileCount) makefile=\(hadMakefile)")
        return Outcome(projectPath: projectDir.path,
                       topLevel: projectDir.lastPathComponent,
                       fileCount: fileCount,
                       hadMakefile: hadMakefile)
    }

    private static func countFiles(in dir: URL) -> Int {
        guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil) else { return 0 }
        var n = 0
        while let item = e.nextObject() as? URL {
            if (try? item.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true { n += 1 }
        }
        return n
    }

    /// Previously imported projects, newest first (for the picker list).
    static func importedProjects() -> [URL] {
        guard let root = importsRoot else { return [] }
        let items = (try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles])) ?? []
        return items.sorted { a, b in
            let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            return da > db
        }
    }
}
