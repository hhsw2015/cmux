import Foundation

enum WorkspaceRemoteSSHBatchCommandBuilder {
    private static let batchSSHControlOptionKeys: Set<String> = [
        "controlmaster",
        "controlpersist",
    ]

    static func daemonTransportArguments(
        configuration: WorkspaceRemoteConfiguration,
        remotePath: String
    ) -> [String] {
        var serveArguments = ["serve", "--stdio"]
        if let slot = configuration.persistentDaemonSlot?.trimmingCharacters(in: .whitespacesAndNewlines),
           !slot.isEmpty {
            serveArguments += ["--persistent", "--slot", slot]
        }
        let daemonCommand = ([remotePath] + serveArguments)
            .map(shellSingleQuoted)
            .joined(separator: " ")
        let script = "exec \(daemonCommand)"
        let command = "sh -c \(shellSingleQuoted(script))"
        return ["-T"]
            + batchArguments(configuration: configuration)
            + ["-o", "RequestTTY=no", configuration.destination, command]
    }

    static func daemonSocketForwardArguments(
        configuration: WorkspaceRemoteConfiguration,
        localPort: Int,
        remoteSocketPath: String
    ) -> [String] {
        ["-N", "-T", "-S", "none"]
            + batchArguments(configuration: configuration)
            + [
                "-o", "ExitOnForwardFailure=yes",
                "-o", "RequestTTY=no",
                "-L", "127.0.0.1:\(localPort):\(remoteSocketPath)",
                configuration.destination,
            ]
    }

    static func reverseRelayControlMasterArguments(
        configuration: WorkspaceRemoteConfiguration,
        controlCommand: String,
        forwardSpec: String
    ) -> [String]? {
        guard let controlPath = sshOptionValue(named: "ControlPath", in: configuration.sshOptions)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !controlPath.isEmpty,
              controlPath.lowercased() != "none" else {
            return nil
        }

        var args = batchArguments(configuration: configuration)
        args += ["-O", controlCommand, "-R", forwardSpec, configuration.destination]
        return args
    }

    static func reverseRelayControlMasterCancelArguments(
        configuration: WorkspaceRemoteConfiguration,
        relayPort: Int
    ) -> [String]? {
        guard relayPort > 0 else { return nil }
        return reverseRelayControlMasterArguments(
            configuration: configuration,
            controlCommand: "cancel",
            forwardSpec: "127.0.0.1:\(relayPort)"
        )
    }

    /// Connection-supervision defaults shared by every daemon-transport and
    /// batch ssh invocation. OpenSSH uses the first value obtained for an
    /// option, so each default is emitted only when the user has not
    /// configured that option themselves — otherwise the user's value would
    /// be dead weight. The keepalive budget (interval 20s x count 6 =
    /// 2 minutes) tolerates transient link stalls instead of tearing down the
    /// transport at the first 40s hiccup; the persistent PTY daemon survives
    /// a teardown anyway, so a faster kill buys nothing but a visible
    /// disconnect/reattach cycle.
    static func sshSupervisionArguments(effectiveSSHOptions: [String]) -> [String] {
        sshSupervisionArguments(configuredKeys: configuredSSHOptionKeys(effectiveSSHOptions))
    }

    /// Set-accepting core so callers that already parsed the option keys
    /// (one-pass parsing per the repo's review rules) can reuse their Set.
    static func sshSupervisionArguments(configuredKeys: Set<String>) -> [String] {
        var args: [String] = []
        if !configuredKeys.contains("connecttimeout") {
            args += ["-o", "ConnectTimeout=6"]
        }
        if !configuredKeys.contains("serveraliveinterval") {
            args += ["-o", "ServerAliveInterval=20"]
        }
        if !configuredKeys.contains("serveralivecountmax") {
            args += ["-o", "ServerAliveCountMax=6"]
        }
        return args
    }

    /// Lowercased option keys present in `options`, parsed in one pass.
    static func configuredSSHOptionKeys(_ options: [String]) -> Set<String> {
        Set(options.compactMap(sshOptionKey))
    }

    private static func batchArguments(configuration: WorkspaceRemoteConfiguration) -> [String] {
        let effectiveSSHOptions = backgroundSSHOptions(configuration.sshOptions)
        let configuredKeys = configuredSSHOptionKeys(effectiveSSHOptions)
        var args: [String] = sshSupervisionArguments(configuredKeys: configuredKeys)
        if !configuredKeys.contains("stricthostkeychecking") {
            args += ["-o", "StrictHostKeyChecking=accept-new"]
        }
        args += ["-o", "BatchMode=yes"]
        // Batch helpers may reuse an existing ControlPath, but must not negotiate a new master.
        args += ["-o", "ControlMaster=no"]
        if let port = configuration.port {
            args += ["-p", String(port)]
        }
        if let identityFile = configuration.identityFile,
           !identityFile.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            args += ["-i", identityFile]
        }
        for option in effectiveSSHOptions {
            args += ["-o", option]
        }
        return args
    }

    private static func hasSSHOptionKey(_ options: [String], key: String) -> Bool {
        let loweredKey = key.lowercased()
        for option in options {
            if sshOptionKey(option) == loweredKey {
                return true
            }
        }
        return false
    }

    private static func normalizedSSHOptions(_ options: [String]) -> [String] {
        options.compactMap { option in
            let trimmed = option.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return trimmed
        }
    }

    private static func backgroundSSHOptions(_ options: [String]) -> [String] {
        normalizedSSHOptions(options).filter { option in
            guard let key = sshOptionKey(option) else { return false }
            return !batchSSHControlOptionKeys.contains(key)
        }
    }

    private static func sshOptionValue(named key: String, in options: [String]) -> String? {
        let loweredKey = key.lowercased()
        for option in normalizedSSHOptions(options) {
            let parts = option.split(
                maxSplits: 1,
                omittingEmptySubsequences: true,
                whereSeparator: { $0 == "=" || $0.isWhitespace }
            )
            guard parts.count == 2, parts[0].lowercased() == loweredKey else {
                continue
            }
            let value = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty {
                return value
            }
        }
        return nil
    }

    private static func sshOptionKey(_ option: String) -> String? {
        let trimmed = option.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed
            .split(whereSeparator: { $0 == "=" || $0.isWhitespace })
            .first
            .map(String.init)?
            .lowercased()
    }

    private static func shellSingleQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }
}
