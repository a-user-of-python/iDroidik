import Foundation

/// Runs shell commands and captures output. Uses posix_spawn (Process/NSTask
/// does not exist on iOS). The app binary is setuid root (via the .deb
/// postinst), so these commands run as root.
enum Shell {

    struct Result {
        let exitCode: Int32
        let stdout: String
        let stderr: String
        var succeeded: Bool { exitCode == 0 }
    }

    /// Run a command with arguments. No shell involved — no injection risk.
    @discardableResult
    static func run(_ executable: String, _ args: String...) -> Result {
        return run(executable, args: args)
    }

    @discardableResult
    static func run(_ executable: String, args: [String]) -> Result {
        // Pipes for stdout/stderr.
        var outPipe: [Int32] = [0, 0]
        var errPipe: [Int32] = [0, 0]
        guard pipe(&outPipe) == 0, pipe(&errPipe) == 0 else {
            return Result(exitCode: -1, stdout: "", stderr: "pipe() failed")
        }

        var fileActions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fileActions)
        posix_spawn_file_actions_adddup2(&fileActions, outPipe[1], STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&fileActions, errPipe[1], STDERR_FILENO)
        posix_spawn_file_actions_addclose(&fileActions, outPipe[0])
        posix_spawn_file_actions_addclose(&fileActions, errPipe[0])
        // Close stdin (commands shouldn't read from our stdin).
        posix_spawn_file_actions_addopen(&fileActions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)

        // Build argv: [executable, args..., nil]. Keep the string buffers
        // alive for the duration of posix_spawn.
        let allArgs = [executable] + args
        var cStrings: [ContiguousArray<CChar>] = allArgs.map { arg in
            var cs = ContiguousArray<CChar>(repeating: 0, count: arg.utf8.count + 1)
            _ = cs.withUnsafeMutableBufferPointer { buf in
                arg.withCString { src in
                    strcpy(buf.baseAddress!, src)
                }
            }
            return cs
        }
        let argv: [UnsafeMutablePointer<CChar>?] = cStrings.indices.map { i in
            cStrings[i].withUnsafeMutableBufferPointer { $0.baseAddress }
        } + [nil]

        var pid: pid_t = 0
        let spawnResult: Int32 = executable.withCString { cExec in
            argv.withUnsafeBufferPointer { argvBuf in
                // argv needs to be mutable for the API; copy to a mutable buffer.
                var mutableArgv = Array(argvBuf)
                return mutableArgv.withUnsafeMutableBufferPointer { mBuf in
                    posix_spawn(&pid, cExec, &fileActions, nil, mBuf.baseAddress, environ)
                }
            }
        }
        posix_spawn_file_actions_destroy(&fileActions)

        guard spawnResult == 0 else {
            close(outPipe[0]); close(outPipe[1])
            close(errPipe[0]); close(errPipe[1])
            return Result(exitCode: -1, stdout: "", stderr: "posix_spawn failed: \(spawnResult)")
        }

        // Parent closes write ends, reads output.
        close(outPipe[1])
        close(errPipe[1])
        let outData = readAll(fd: outPipe[0])
        let errData = readAll(fd: errPipe[0])
        close(outPipe[0])
        close(errPipe[0])

        var status: Int32 = 0
        waitpid(pid, &status, 0)
        // Keep references alive until after spawn returns.
        _ = cStrings

        let code: Int32 = (status & 0x7F == 0) ? (status >> 8) : -1
        return Result(
            exitCode: code,
            stdout: String(data: outData, encoding: .utf8) ?? "",
            stderr: String(data: errData, encoding: .utf8) ?? ""
        )
    }

    /// Run a shell script string via /bin/sh -c. Use only for pipelines/globs
    /// that need a shell; prefer run(_:_:) otherwise.
    @discardableResult
    static func sh(_ script: String) -> Result {
        return run("/bin/sh", args: ["-c", script])
    }

    /// Free bytes on the filesystem containing path.
    static func freeBytes(atPath path: String) -> Int64? {
        var stat = statvfs()
        guard statvfs(path, &stat) == 0 else { return nil }
        return Int64(stat.f_bavail) * Int64(stat.f_frsize)
    }

    // MARK: - Private

    private static func readAll(fd: Int32) -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 32768)
        while true {
            let n = read(fd, &buffer, buffer.count)
            if n <= 0 { break }
            data.append(buffer, count: n)
        }
        return data
    }
}
