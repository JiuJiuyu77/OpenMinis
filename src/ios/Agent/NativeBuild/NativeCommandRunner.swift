//
//  NativeCommandRunner.swift
//  Minis — 原生进程执行（不经过 iSH 的 Linux 模拟层）
//
//  posix_spawn + 管道读取，逐行回调；支持超时与取消（整组 SIGTERM → SIGKILL）。
//  与 iSH 路径的语义差别：这里跑在真实文件系统上，路径就是设备绝对路径。
//

import Foundation

enum NativeCommandRunner {

    struct Result {
        var output: String
        var exitCode: Int32
        var duration: TimeInterval
        var timedOut: Bool
        var ok: Bool { exitCode == 0 && !timedOut }
    }

    private static let queue = DispatchQueue(label: "app.minis.native-build.runner", qos: .userInitiated)

    /// 单引号安全转义（与 sh 一致）。
    static func shellQuote(_ value: String) -> String {
        if value.isEmpty { return "''" }
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// 运行一条命令。
    /// - Parameters:
    ///   - command: shell 脚本（会交给 shell -lc 执行）
    ///   - directory: 工作目录
    ///   - environment: 子进程环境
    ///   - timeout: 超时秒数（<=0 表示不限）
    ///   - onLine: 每读到一行调用一次（在后台队列上）
    static func run(command: String,
                    in directory: String?,
                    environment: [String: String],
                    timeout: TimeInterval,
                    onLine: ((String) -> Void)? = nil,
                    onSpawn: ((pid_t) -> Void)? = nil) async -> Result {
        let started = Date()
        let shell = NativeToolchain.shared.shellPath ?? "/bin/sh"
        let script: String
        if let directory, !directory.isEmpty {
            script = "cd " + shellQuote(directory) + " || exit 96\n" + command
        } else {
            script = command
        }

        var argv: [String] = [shell, "-lc", script]
        var envPairs: [String] = []
        for (key, value) in environment where !key.contains("=") {
            envPairs.append("\(key)=\(value)")
        }

        var outPipe: [Int32] = [-1, -1]
        guard pipe(&outPipe) == 0 else {
            return Result(output: "无法创建管道", exitCode: -1, duration: 0, timedOut: false)
        }

        // On the iOS 26 SDK, posix_spawn_file_actions_t is UnsafeMutableRawPointer,
        // so it must be held as an Optional to pass `&actions` to the C APIs.
        var actions: posix_spawn_file_actions_t? = nil
        posix_spawn_file_actions_init(&actions)
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, outPipe[1], 1)
        posix_spawn_file_actions_adddup2(&actions, outPipe[1], 2)
        posix_spawn_file_actions_addclose(&actions, outPipe[0])
        posix_spawn_file_actions_addclose(&actions, outPipe[1])

        var attr: posix_spawnattr_t? = nil
        posix_spawnattr_init(&attr)
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF))
        posix_spawnattr_setpgroup(&attr, 0)
        var defaults = sigset_t()
        sigemptyset(&defaults)
        posix_spawnattr_setsigdefault(&attr, &defaults)

        let pid = await withCheckedContinuation { (cont: CheckedContinuation<pid_t, Never>) in
            queue.async {
                var child: pid_t = -1
                let rc = runSpawn(&child, shell, argv, envPairs, &actions, &attr)
                posix_spawn_file_actions_destroy(&actions)
                posix_spawnattr_destroy(&attr)
                close(outPipe[1])
                cont.resume(returning: rc == 0 ? child : -1)
            }
        }

        guard pid > 0 else {
            close(outPipe[0])
            return Result(output: "无法启动进程（posix_spawn 失败，通常是缺少 no-sandbox 权限）",
                          exitCode: -1, duration: Date().timeIntervalSince(started), timedOut: false)
        }
        onSpawn?(pid)

        let collector = LineCollector(onLine: onLine)
        let reader = DispatchQueue(label: "app.minis.native-build.reader")
        let finished = DispatchSemaphore(value: 0)

        reader.async {
            let handle = FileHandle(fileDescriptor: outPipe[0], closeOnDealloc: true)
            while true {
                let data = handle.availableData
                if data.isEmpty { break }
                collector.append(data)
            }
            finished.signal()
        }

        let deadline = timeout > 0 ? Date().addingTimeInterval(timeout) : Date.distantFuture
        var timedOut = false
        var status: Int32 = 0

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            queue.async {
                while true {
                    var st: Int32 = 0
                    let r = waitpid(pid, &st, WNOHANG)
                    if r == pid {
                        status = st
                        break
                    }
                    if r < 0 && errno != EINTR { break }
                    if Date() > deadline {
                        timedOut = true
                        kill(-pid, SIGTERM)
                        usleep(800_000)
                        kill(-pid, SIGKILL)
                        _ = waitpid(pid, &st, 0)
                        status = st
                        break
                    }
                    usleep(120_000)
                }
                cont.resume()
            }
        }

        _ = finished.wait(timeout: .now() + 2)
        collector.flush()

        let code: Int32 = (status & 0x7f) == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
        return Result(output: collector.text,
                      exitCode: code,
                      duration: Date().timeIntervalSince(started),
                      timedOut: timedOut)
    }

    private static func runSpawn(_ child: inout pid_t,
                                 _ executable: String,
                                 _ args: [String],
                                 _ env: [String],
                                 _ actions: inout posix_spawn_file_actions_t?,
                                 _ attr: inout posix_spawnattr_t?) -> Int32 {
        var cArgs: [UnsafeMutablePointer<CChar>?] = args.map { strdup($0) }
        var cEnv: [UnsafeMutablePointer<CChar>?] = env.map { strdup($0) }
        cArgs.append(nil)
        cEnv.append(nil)
        defer {
            for p in cArgs where p != nil { free(p) }
            for p in cEnv where p != nil { free(p) }
        }
        return executable.withCString { path in
            posix_spawn(&child, path, &actions, &attr, &cArgs, &cEnv)
        }
    }
}

/// 把字节流按行切分，避免多字节字符被截断。
private final class LineCollector {
    private var buffer = Data()
    private var pending = ""
    private var all = ""
    private let onLine: ((String) -> Void)?
    private let lock = NSLock()

    init(onLine: ((String) -> Void)?) { self.onLine = onLine }

    func append(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        buffer.append(data)
        guard let text = String(data: buffer, encoding: .utf8) else { return }
        buffer.removeAll(keepingCapacity: true)
        pending += text
        while let idx = pending.firstIndex(of: "\n") {
            let line = String(pending[pending.startIndex..<idx])
            pending = String(pending[pending.index(after: idx)...])
            emit(line)
        }
    }

    func flush() {
        lock.lock(); defer { lock.unlock() }
        if !pending.isEmpty {
            emit(pending)
            pending = ""
        }
        if let rest = String(data: buffer, encoding: .isoLatin1), !rest.isEmpty {
            emit(rest)
            buffer.removeAll()
        }
    }

    private func emit(_ line: String) {
        all += line + "\n"
        onLine?(line)
    }

    var text: String {
        lock.lock(); defer { lock.unlock() }
        return all
    }
}
