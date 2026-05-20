import Foundation

/// One host that runs (or could run) a herdr daemon. Localhost is a host
/// just like any remote machine — same protocol, same `HerdrHost` shape.
struct HerdrHost: Identifiable, Codable, Equatable, Hashable, Sendable {
    let id: UUID
    var displayName: String
    var transport: Transport
    var sessionName: String      // herdr `--session <name>` namespace
    let addedAt: Date

    /// Whether this is the auto-registered localhost entry. Localhost is
    /// always present and cannot be removed.
    var isLocalhost: Bool {
        if case .localUDS = transport { return true }
        return false
    }

    enum Transport: Equatable, Hashable, Sendable {
        /// Unix domain socket on the same machine. The session name is
        /// resolved via herdr's standard path lookup (`~/.config/herdr/...`).
        case localUDS
        /// SSH stdio bridge to a remote machine.
        ///
        /// - `target`: ssh's host argument (`user@host`, `~/.ssh/config` alias).
        /// - `extraArgs`: extra args inserted between `sshExecutable` (or the
        ///   default `/usr/bin/ssh`) and `target`. e.g. `["-i", "~/key.pem",
        ///   "-p", "9022", "-o", "ProxyCommand=..."]`. For sshpass it also
        ///   carries the inner `ssh` token plus the inner ssh options.
        /// - `skipDefaultOptions`: when true cmux's default options
        ///   (BatchMode=yes, ControlMaster, keepalives) are NOT prepended.
        ///   Required for sshpass (which doesn't understand them in front of
        ///   its own `-p PWD ssh` invocation).
        /// - `sshExecutable`: override `/usr/bin/ssh` (e.g. sshpass path).
        /// - `remoteBinaryPath`: override the remote `herdr-cmux` binary
        ///   path. Default `nil` = use `herdr-cmux` from the remote `$PATH`.
        case sshStdio(
            target: String,
            extraArgs: [String] = [],
            skipDefaultOptions: Bool = false,
            sshExecutable: String? = nil,
            remoteBinaryPath: String? = nil
        )
    }

    static let localhostID = UUID(uuidString: "00000000-0000-0000-0000-00000000C111")!

    static func localhost(sessionName: String? = nil) -> HerdrHost {
        HerdrHost(
            id: localhostID,
            displayName: "localhost",
            transport: .localUDS,
            sessionName: sessionName ?? Self.defaultLocalSessionName(),
            addedAt: Date(timeIntervalSince1970: 0)
        )
    }

    /// Per-bundle herdr session name so cmux / cmux DEV / cmux STAGING
    /// don't collide on each other's panes. Mirrors the bundle suffix
    /// rule used by the existing tagged debug socket scheme.
    static func defaultLocalSessionName() -> String {
        let bundleID = Bundle.main.bundleIdentifier ?? "cmux"
        let lower = bundleID.lowercased()
        if lower.contains("staging") { return "cmux-staging" }
        if lower.contains("debug") || lower.contains("dev") { return "cmux-dev" }
        return "cmux"
    }

    /// Path to the local herdr API socket for this host's session. Only
    /// meaningful for `.localUDS` hosts — `.sshStdio` hosts' sockets
    /// live on the remote filesystem, not here. Use the transport
    /// factory or per-host pump cache for SSH hosts instead of trying
    /// to construct a path locally.
    var localApiSocketPath: String {
        (("~/.config/herdr/sessions/" + sessionName + "/herdr.sock") as NSString)
            .expandingTildeInPath
    }
}

// MARK: - Custom Codable for Transport (backwards-compat with old
// `_0`-keyed sshStdio that only stored `target`).

extension HerdrHost.Transport: Codable {
    private enum CodingKeys: String, CodingKey {
        case localUDS
        case sshStdio
    }

    private struct SSHStdioPayload: Codable {
        var target: String
        var extraArgs: [String]?
        var skipDefaultOptions: Bool?
        var sshExecutable: String?
        var remoteBinaryPath: String?

        // Old synthesized format used `_0` for the single associated value.
        enum CodingKeys: String, CodingKey {
            case target, extraArgs, skipDefaultOptions, sshExecutable, remoteBinaryPath
            case legacyZero = "_0"
        }

        init(target: String,
             extraArgs: [String],
             skipDefaultOptions: Bool,
             sshExecutable: String?,
             remoteBinaryPath: String?) {
            self.target = target
            self.extraArgs = extraArgs.isEmpty ? nil : extraArgs
            self.skipDefaultOptions = skipDefaultOptions ? true : nil
            self.sshExecutable = sshExecutable
            self.remoteBinaryPath = remoteBinaryPath
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            if let t = try c.decodeIfPresent(String.self, forKey: .target) {
                self.target = t
            } else if let z = try c.decodeIfPresent(String.self, forKey: .legacyZero) {
                self.target = z
            } else {
                throw DecodingError.dataCorruptedError(
                    forKey: .target, in: c,
                    debugDescription: "sshStdio payload missing target"
                )
            }
            self.extraArgs = try c.decodeIfPresent([String].self, forKey: .extraArgs)
            self.skipDefaultOptions = try c.decodeIfPresent(Bool.self, forKey: .skipDefaultOptions)
            self.sshExecutable = try c.decodeIfPresent(String.self, forKey: .sshExecutable)
            self.remoteBinaryPath = try c.decodeIfPresent(String.self, forKey: .remoteBinaryPath)
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(target, forKey: .target)
            try c.encodeIfPresent(extraArgs, forKey: .extraArgs)
            try c.encodeIfPresent(skipDefaultOptions, forKey: .skipDefaultOptions)
            try c.encodeIfPresent(sshExecutable, forKey: .sshExecutable)
            try c.encodeIfPresent(remoteBinaryPath, forKey: .remoteBinaryPath)
        }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if c.contains(.localUDS) {
            self = .localUDS
            return
        }
        if c.contains(.sshStdio) {
            let payload = try c.decode(SSHStdioPayload.self, forKey: .sshStdio)
            self = .sshStdio(
                target: payload.target,
                extraArgs: payload.extraArgs ?? [],
                skipDefaultOptions: payload.skipDefaultOptions ?? false,
                sshExecutable: payload.sshExecutable,
                remoteBinaryPath: payload.remoteBinaryPath
            )
            return
        }
        throw DecodingError.dataCorruptedError(
            forKey: .localUDS, in: c,
            debugDescription: "Unknown HerdrHost.Transport variant"
        )
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .localUDS:
            try c.encode([String: String](), forKey: .localUDS)
        case .sshStdio(let target, let extraArgs, let skipDefault, let sshExe, let remoteBin):
            try c.encode(
                SSHStdioPayload(
                    target: target,
                    extraArgs: extraArgs,
                    skipDefaultOptions: skipDefault,
                    sshExecutable: sshExe,
                    remoteBinaryPath: remoteBin
                ),
                forKey: .sshStdio
            )
        }
    }
}
