import Foundation

/// Builds launch invocations for the `cmux-tmux` binary, in either
/// the local (direct `Process`) or SSH (wrapped) case. Mirrors
/// `SSHCommandBuilder` for the `.cmuxTmuxLocal` / `.cmuxTmuxSSH`
/// transport cases so call sites that need a fresh subprocess
/// (the API actor, the display spawn path) don't each re-derive
/// the logic.
///
/// `cmux-tmux` shares the SSH-stdio framing rules with herdr-cmux:
/// the same `--session NAME` global flag goes before the
/// subcommand, and remote SSH invocations get cmux's "always
/// good" ssh defaults (ControlMaster, keepalives, ConnectTimeout)
/// unless the host pins `skipDefaultOptions: true`.
enum CmuxTmuxCommandBuilder {

    /// Build the launch invocation for `cmux-tmux <args>` against
    /// the given host. Returns nil for non-cmux-tmux transports.
    ///
    /// `subArgs` is the cmux-tmux argv tail (e.g. `["serve"]` or
    /// `["raw-pty-attach", "--pane", "%3"]`). The builder
    /// prepends the global `--session NAME` flag automatically.
    static func build(
        for host: HerdrHost,
        subArgs: [String]
    ) -> (executable: String, args: [String])? {
        switch host.transport {
        case .cmuxTmuxLocal(let pinned):
            let binary = pinned ?? defaultLocalBinary()
            var args: [String] = []
            if !host.sessionName.isEmpty {
                args.append("--session")
                args.append(host.sessionName)
            }
            args.append(contentsOf: subArgs)
            return (binary, args)
        case .cmuxTmuxSSH(let target, let extraArgs, let skipDefault, let sshExe, _):
            let executable = sshExe ?? "/usr/bin/ssh"
            let isWrapped = SSHCommandBuilder.isSshpassWrapper(executable)

            var args: [String] = []
            if isWrapped {
                // Same sshpass split as SSHCommandBuilder.build.
                let split = splitAroundInnerSSH(extraArgs)
                args.append(contentsOf: split.beforeSsh)
                if let sshToken = split.sshToken {
                    args.append(sshToken)
                    if !skipDefault {
                        args.append(contentsOf: SSHStdioTransport.alwaysGoodOptions)
                    }
                    args.append(contentsOf: split.afterSsh)
                } else {
                    args.append(contentsOf: extraArgs)
                }
            } else {
                if !skipDefault {
                    args.append(contentsOf: SSHStdioTransport.defaultOptions)
                }
                args.append(contentsOf: extraArgs)
            }

            args.append(target)
            args.append("--")

            var remoteCommand: [String] = [remoteBinaryPath(for: host)]
            if !host.sessionName.isEmpty {
                remoteCommand.append("--session")
                remoteCommand.append(host.sessionName)
            }
            remoteCommand.append(contentsOf: subArgs)
            args.append(contentsOf: remoteCommand)
            return (executable, args)
        case .localUDS, .sshStdio:
            return nil
        }
    }

    /// Resolve the remote `cmux-tmux` binary path for a
    /// `.cmuxTmuxSSH` host. Mirrors
    /// `SSHCommandBuilder.remoteBinaryPath` but for cmux-tmux.
    static func remoteBinaryPath(for host: HerdrHost) -> String {
        if case .cmuxTmuxSSH(_, _, _, _, let remoteBin) = host.transport,
           let path = remoteBin, !path.isEmpty {
            return path
        }
        return defaultRemoteBinaryShellExpression
    }

    /// Local fallback when the user hasn't pinned a binary path:
    /// `cmux-tmux` from the launching shell's `$PATH`.
    static func defaultLocalBinary() -> String {
        "cmux-tmux"
    }

    /// Same lookup heuristic as herdr-cmux but for the cmux-tmux
    /// binary — `command -v cmux-tmux` first, then
    /// `$HOME/.local/bin/cmux-tmux`. Used as a remote shell
    /// expression that ssh interpolates verbatim.
    static let defaultRemoteBinaryShellExpression =
        "\"$(command -v cmux-tmux || echo $HOME/.local/bin/cmux-tmux)\""

    // MARK: - Helpers

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
