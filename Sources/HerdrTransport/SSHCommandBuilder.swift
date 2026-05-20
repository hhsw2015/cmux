import Foundation

/// Centralizes the rules for converting a `HerdrHost.Transport.sshStdio`
/// case + a remote subcommand into the `(executable, args)` pair we hand
/// to `Process`. All callers that spawn ssh (api-bridge, raw-pty-attach,
/// remote install scp/chmod, and the connection probe) MUST go through
/// this builder so behavior stays consistent.
///
/// Default-injection policy: cmux's "always-good" defaults
/// (ControlMaster reuse, keepalives, no-tty, ConnectTimeout) are applied
/// in EVERY case unless `skipDefaultOptions` is true. The non-interactive
/// `BatchMode=yes` default is only added for plain ssh — sshpass-wrapped
/// invocations need interactive auth, and BatchMode=yes would block the
/// very password prompt sshpass relies on.
enum SSHCommandBuilder {

    /// Build the launch invocation for an sshStdio host running a
    /// `remoteCommand` on the remote side.
    ///
    /// `remoteCommand` is the full argv to execute on the remote (e.g.
    /// `["herdr-cmux", "--session", "cmux-dev", "api-bridge"]`). Pass
    /// the empty array to launch ssh with no remote command (e.g. for
    /// scp where the caller wraps differently).
    ///
    /// Returns nil for non-ssh transports.
    static func build(
        for host: HerdrHost,
        remoteCommand: [String]
    ) -> (executable: String, args: [String])? {
        guard case .sshStdio(let target, let extraArgs, let skipDefault, let sshExe, _) = host.transport else {
            return nil
        }

        let executable = sshExe ?? "/usr/bin/ssh"
        let isWrapped = isSshpassWrapper(executable)

        var args: [String] = []

        if isWrapped {
            // sshpass case: extraArgs already contains the inner "ssh"
            // token. Split around it and inject our defaults right after
            // so they apply to the inner ssh, not sshpass itself. Drop
            // BatchMode (would block sshpass's password mechanism).
            let split = splitAroundInnerSSH(extraArgs)
            args.append(contentsOf: split.beforeSsh)
            if let sshToken = split.sshToken {
                args.append(sshToken)
                if !skipDefault {
                    args.append(contentsOf: SSHStdioTransport.alwaysGoodOptions)
                }
                args.append(contentsOf: split.afterSsh)
            } else {
                // sshpass with no inner "ssh" token (unusual). Append
                // user args verbatim and trust them.
                args.append(contentsOf: extraArgs)
            }
        } else {
            if !skipDefault {
                args.append(contentsOf: SSHStdioTransport.defaultOptions)
            }
            args.append(contentsOf: extraArgs)
        }

        args.append(target)
        if !remoteCommand.isEmpty {
            args.append("--")
            args.append(contentsOf: remoteCommand)
        }
        return (executable, args)
    }

    /// Resolve the remote `herdr-cmux` binary path for an sshStdio host.
    /// Returns the override when the user supplied one, otherwise the
    /// bare `herdr-cmux` (which relies on the remote `$PATH`).
    static func remoteBinaryPath(for host: HerdrHost) -> String {
        if case .sshStdio(_, _, _, _, let remoteBin) = host.transport,
           let path = remoteBin, !path.isEmpty {
            return path
        }
        return "herdr-cmux"
    }

    // MARK: - Helpers

    static func isSshpassWrapper(_ executablePath: String) -> Bool {
        let base = (executablePath as NSString).lastPathComponent
        return base == "sshpass"
    }

    private struct InnerSplit {
        var beforeSsh: [String]
        var sshToken: String?
        var afterSsh: [String]
    }

    private static func splitAroundInnerSSH(_ args: [String]) -> InnerSplit {
        for (idx, t) in args.enumerated() {
            let base = (t as NSString).lastPathComponent
            if base == "ssh" {
                let before = Array(args.prefix(idx))
                let after = Array(args.suffix(from: idx + 1))
                return InnerSplit(beforeSsh: before, sshToken: t, afterSsh: after)
            }
        }
        return InnerSplit(beforeSsh: [], sshToken: nil, afterSsh: args)
    }
}
