//
//  MachOInjector.swift
//  Minis — 打壳（给 App/可执行文件注入 dylib 的 Mach-O 手术）
//
//  为什么手写：iOS 上没有 install_name_tool，也没有 optool/insert_dylib。
//  打壳只做一件很小的事：在一个 arm64/arm64e Mach-O 的 Load Command 区末尾
//  追加一条 `LC_LOAD_DYLIB`，指向 `@executable_path/Frameworks/<name>.dylib`，
//  然后把 `ncmds` 与 `sizeofcmds` 加一。只要 Load Command 区和第一个 section
//  之间有空隙（几乎所有真实二进制都有），就不需要重建整个文件。
//
//  这**不是**重签名器：注入后仍必须用 ldid 重新签名，否则内核拒绝加载。
//  我们把这一步写进诊断提示，而不是假装成功。
//

import Foundation

enum MachOInjector {

    enum InjectError: LocalizedError {
        case notMachO
        case thinOnly
        case noLoadCommandRoom(need: Int, available: Int)
        case writeFailed(String)
        case signatureInvalidated

        var errorDescription: String? {
            switch self {
            case .notMachO: return "Not a 64-bit Mach-O executable"
            case .thinOnly: return "Fat (universal) binaries are not supported yet — thin the slice first"
            case .noLoadCommandRoom(let need, let available):
                return "No room for the load command (need \(need) bytes, \(available) available). Rebuild the target with more header padding."
            case .writeFailed(let reason): return "Could not patch the binary: \(reason)"
            case .signatureInvalidated:
                return "The binary is now unsigned — re-sign it with ldid before installing"
            }
        }
    }

    /// Result of a successful injection.
    struct Outcome {
        let executable: URL
        let loadPath: String
        let injectedBytes: Int
        /// Codesignature blob data offset that was zeroed out (if any), so the
        /// caller knows a re-sign is mandatory.
        let clearedSignature: Bool
    }

    // LC_LOAD_DYLIB
    private static let LC_LOAD_DYLIB: UInt32 = 0xC
    private static let MH_MAGIC_64: UInt32 = 0xfeed_facf
    private static let MH_CIGAM_64: UInt32 = 0xcffa_edfe
    private static let FAT_MAGIC: UInt32 = 0xcafe_babe
    private static let FAT_MAGIC_64: UInt32 = 0xcafe_babf
    private static let LC_CODE_SIGNATURE: UInt32 = 0x1d
    private static let LC_SEGMENT_64: UInt32 = 0x19

    /// Append `LC_LOAD_DYLIB` for `dylibName` to the executable at `binary`.
    ///
    /// - Parameter executablePath: value stored in the load command. Defaults
    ///   to `@executable_path/Frameworks/<dylibName>`.
    @discardableResult
    static func addDylibLoad(_ dylibName: String,
                             to binary: URL,
                             executablePath: String? = nil) throws -> Outcome {
        let loadPath = executablePath ?? "@executable_path/Frameworks/\(dylibName)"
        guard let handle = try? FileHandle(forUpdating: binary) else {
            throw InjectError.writeFailed("cannot open \(binary.path)")
        }
        defer { try? handle.close() }

        guard let head = try? handle.read(upToCount: 32), head.count == 32 else {
            throw InjectError.notMachO
        }
        let magic = head.withUnsafeBytes { $0.load(as: UInt32.self) }
        if magic == FAT_MAGIC || magic == FAT_MAGIC_64 { throw InjectError.thinOnly }
        guard magic == MH_MAGIC_64 || magic == MH_CIGAM_64 else { throw InjectError.notMachO }
        let isSwapped = (magic == MH_CIGAM_64)

        func u32(_ d: Data, _ off: Int) -> UInt32 {
            let raw = d.withUnsafeBytes { $0.load(fromByteOffset: off, as: UInt32.self) }
            return isSwapped ? raw.byteSwapped : raw
        }

        // mach_header_64: magic, cputype, cpusubtype, filetype, ncmds, sizeofcmds, flags, reserved
        let ncmds = u32(head, 16)
        let sizeofcmds = u32(head, 20)
        let headerSize = 32
        let lcStart = headerSize
        let lcEnd = lcStart + Int(sizeofcmds)

        // --- Walk the load commands: find the first section's file offset and
        //     the LC_CODE_SIGNATURE (which must be invalidated).
        guard let lcs = try? handle.read(upToCount: Int(sizeofcmds)), lcs.count == Int(sizeofcmds) else {
            throw InjectError.notMachO
        }

        var firstSectionOffset: Int = .max
        var signatureRange: (offset: Int, size: Int)?
        var cursor = 0
        while cursor + 8 <= lcs.count {
            let cmd = u32(lcs, cursor)
            let cmdsize = Int(u32(lcs, cursor + 4))
            guard cmdsize >= 8, cursor + cmdsize <= lcs.count else { break }
            if cmd == LC_SEGMENT_64 {
                // segment_command_64: cmd(4) cmdsize(4) segname(16) vmaddr(8) vmsize(8)
                // fileoff(8) filesize(8) maxprot(4) initprot(4) nsects(4) flags(4) = 72
                let nsects = Int(u32(lcs, cursor + 64))
                let segmentFileOff = readU64(lcs, cursor + 40, isSwapped)
                for s in 0..<nsects {
                    let base = cursor + 72 + s * 80
                    guard base + 80 <= lcs.count else { break }
                    // section_64: sectname(16) segname(16) addr(8) size(8) offset(4) ...
                    let sectionOffset = Int(u32(lcs, base + 48))
                    if sectionOffset > 0, sectionOffset < firstSectionOffset, segmentFileOff >= 0 {
                        firstSectionOffset = sectionOffset
                    }
                }
            } else if cmd == LC_CODE_SIGNATURE {
                // linkedit_data_command: cmd, cmdsize, dataoff(4), datasize(4)
                let dataoff = Int(u32(lcs, cursor + 8))
                let datasize = Int(u32(lcs, cursor + 12))
                signatureRange = (dataoff, datasize)
            }
            cursor += cmdsize
        }
        if firstSectionOffset == .max { firstSectionOffset = lcEnd }

        // --- Build the new load command.
        let nameBytes = Array(loadPath.utf8) + [0]
        var cmdSize = 24 + nameBytes.count
        cmdSize = (cmdSize + 7) & ~7   // 8-byte aligned (arm64 requirement)
        let available = firstSectionOffset - lcEnd
        guard available >= cmdSize else {
            throw InjectError.noLoadCommandRoom(need: cmdSize, available: max(0, available))
        }

        var cmd = Data()
        appendU32(&cmd, LC_LOAD_DYLIB)
        appendU32(&cmd, UInt32(cmdSize))
        appendU32(&cmd, 24)            // name offset (right after dylib_command)
        appendU32(&cmd, 2)             // timestamp
        appendU32(&cmd, 0x0001_0000)   // current_version 1.0.0
        appendU32(&cmd, 0x0001_0000)   // compatibility_version 1.0.0
        cmd.append(contentsOf: nameBytes)
        if cmd.count < cmdSize { cmd.append(Data(repeating: 0, count: cmdSize - cmd.count)) }

        // --- Patch: ncmds += 1, sizeofcmds += cmdSize, write cmd at lcEnd.
        var ncmdsBytes = u32Bytes(ncmds + 1, isSwapped)
        var sizeofcmdsBytes = u32Bytes(sizeofcmds + UInt32(cmdSize), isSwapped)
        do {
            try handle.seek(toOffset: 16)
            try handle.write(contentsOf: ncmdsBytes)
            try handle.write(contentsOf: sizeofcmdsBytes)
            ncmdsBytes.removeAll(); sizeofcmdsBytes.removeAll()

            try handle.seek(toOffset: UInt64(lcEnd))
            try handle.write(contentsOf: cmd)
        } catch {
            throw InjectError.writeFailed(error.localizedDescription)
        }

        // --- Invalidate any existing code signature: a stale signature makes
        //     the kernel kill the process at exec, which looks like "no sandbox
        //     permission" in posix_spawn. Zeroing the LC's blob keeps the
        //     command valid while telling the kernel nothing is signed.
        var cleared = false
        if let sig = signatureRange, sig.size > 0 {
            if let zero = try? handle.seek(toOffset: UInt64(sig.offset)) {
                _ = zero
                try? handle.write(contentsOf: Data(repeating: 0, count: min(sig.size, 1 << 20)))
                cleared = true
            }
        }
        return Outcome(executable: binary, loadPath: loadPath,
                       injectedBytes: cmdSize, clearedSignature: cleared)
    }

    // MARK: - Helpers

    private static func readU64(_ d: Data, _ off: Int, _ swapped: Bool) -> Int64 {
        guard off + 8 <= d.count else { return 0 }
        let raw = d.withUnsafeBytes { $0.load(fromByteOffset: off, as: UInt64.self) }
        return Int64(bitPattern: swapped ? raw.byteSwapped : raw)
    }

    private static func u32Bytes(_ v: UInt32, _ swapped: Bool) -> Data {
        var value = swapped ? v.byteSwapped : v
        return withUnsafeBytes(of: &value) { Data($0) }
    }

    private static func appendU32(_ d: inout Data, _ v: UInt32) {
        var value = v
        d.append(withUnsafeBytes(of: &value) { Data($0) })
    }

    /// Cheap check used by diagnostics: can this binary hold one more LC?
    static func hasHeaderRoom(_ binary: URL, extra: Int = 128) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: binary) else { return false }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 32), head.count == 32 else { return false }
        let magic = head.withUnsafeBytes { $0.load(as: UInt32.self) }
        let swapped = (magic == MH_CIGAM_64)
        guard magic == MH_MAGIC_64 || swapped else { return false }
        let rawSize = head.withUnsafeBytes { $0.load(fromByteOffset: 20, as: UInt32.self) }
        let sizeofcmds = Int(swapped ? rawSize.byteSwapped : rawSize)
        guard sizeofcmds > 0,
              let lcs = try? handle.read(upToCount: sizeofcmds),
              lcs.count == sizeofcmds else { return false }

        var firstSection = Int.max
        var cursor = 0
        while cursor + 8 <= lcs.count {
            func u32(_ off: Int) -> UInt32 {
                let raw = lcs.withUnsafeBytes { $0.load(fromByteOffset: off, as: UInt32.self) }
                return swapped ? raw.byteSwapped : raw
            }
            let command = u32(cursor)
            let cmdsize = Int(u32(cursor + 4))
            guard cmdsize >= 8, cursor + cmdsize <= lcs.count else { break }
            if command == LC_SEGMENT_64 {
                let nsects = Int(u32(cursor + 64))
                for s in 0..<nsects {
                    let base = cursor + 72 + s * 80
                    guard base + 52 <= lcs.count else { break }
                    let sectionOffset = Int(u32(base + 48))
                    if sectionOffset > 0, sectionOffset < firstSection { firstSection = sectionOffset }
                }
            }
            cursor += cmdsize
        }
        if firstSection == .max { firstSection = 32 + sizeofcmds }
        return (firstSection - (32 + sizeofcmds)) >= extra
    }
}
