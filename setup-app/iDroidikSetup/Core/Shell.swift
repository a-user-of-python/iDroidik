import Foundation

/// Runs shell commands and captures output. The app binary is setuid root
/// (via the .deb postinst), so these commands run as root.
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
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executable)
        proc.arguments = args
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        do {
            try proc.run()
        } catch {
            return Result(exitCode: -1, stdout: "", stderr: "failed to launch \(executable): \(error)")
        }
        proc.waitUntilExit()
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        return Result(
            exitCode: proc.terminationStatus,
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
}
