import Foundation

public struct SSHTarget: Equatable, Hashable, Codable, Sendable {
    public var user: String
    public var host: String
    public init(user: String, host: String) { self.user = user; self.host = host }

    public var destination: String { "\(user)@\(host)" }

    /// Letters, digits, dot, dash and underscore only: no spaces or shell metacharacters.
    public var isValid: Bool {
        func ok(_ s: String) -> Bool {
            !s.isEmpty && s.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || ".-_".unicodeScalars.contains($0) }
        }
        return ok(user) && ok(host)
    }
}

public enum RemoteError: Error, Equatable {
    case commandFailed(status: Int32, stderr: String)
}

/// A way to run commands and move files on a cabinet.
public protocol RemoteShell: Sendable {
    func run(_ command: String) async throws -> CommandResult
    func fetch(remotePath: String, to localPath: String) async throws -> CommandResult
    func push(localPath: String, toRemotePath remotePath: String) async throws -> CommandResult
}

/// `ssh`/`rsync` in BatchMode (key auth only, never prompts) with an 8 second connect timeout.
public struct SSHShell: RemoteShell {
    public let target: SSHTarget
    private let runner: ProcessRunning
    private let commandTimeout: TimeInterval
    private static let sshOptions = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=8"]

    public init(target: SSHTarget, runner: ProcessRunning = SystemProcessRunner(), commandTimeout: TimeInterval = 120) {
        self.target = target; self.runner = runner; self.commandTimeout = commandTimeout
    }

    public func run(_ command: String) async throws -> CommandResult {
        try check(await runner.run("/usr/bin/ssh", Self.sshOptions + [target.destination, command], timeout: commandTimeout))
    }

    public func fetch(remotePath: String, to localPath: String) async throws -> CommandResult {
        try check(await runner.run("/usr/bin/rsync", rsyncArgs(src: remote(remotePath), dst: localPath), timeout: 3600))
    }

    public func push(localPath: String, toRemotePath remotePath: String) async throws -> CommandResult {
        try check(await runner.run("/usr/bin/rsync", rsyncArgs(src: localPath, dst: remote(remotePath)), timeout: 3600))
    }

    private func remote(_ path: String) -> String { "\(target.destination):\(ShellQuote.quote(path))" }

    private func rsyncArgs(src: String, dst: String) -> [String] {
        ["-rlt", "-e", "ssh " + Self.sshOptions.joined(separator: " "), src, dst]
    }

    private func check(_ r: CommandResult) throws -> CommandResult {
        guard r.succeeded else {
            // OpenSSH prints "** WARNING: ... post-quantum ..." lines on every connection; they bury the real error
            let lines = r.stderr.split(separator: "\n", omittingEmptySubsequences: true).filter { !$0.hasPrefix("** ") }
            throw RemoteError.commandFailed(status: r.status, stderr: lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return r
    }
}
