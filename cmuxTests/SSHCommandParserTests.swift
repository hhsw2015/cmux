import XCTest
@testable import cmux

final class SSHCommandParserTests: XCTestCase {

    // MARK: - Tokenizer

    func testTokenizeSimple() throws {
        let tokens = try SSHCommandParser.tokenize("ssh user@host -i key.pem")
        XCTAssertEqual(tokens, ["ssh", "user@host", "-i", "key.pem"])
    }

    func testTokenizeSingleQuoted() throws {
        let tokens = try SSHCommandParser.tokenize("sshpass -p 'pa ss' ssh root@x")
        XCTAssertEqual(tokens, ["sshpass", "-p", "pa ss", "ssh", "root@x"])
    }

    func testTokenizeDoubleQuotedWithEscape() throws {
        let tokens = try SSHCommandParser.tokenize(
            #"ssh -o "ProxyCommand=foo \"bar\" baz" host"#
        )
        XCTAssertEqual(tokens, ["ssh", "-o", #"ProxyCommand=foo "bar" baz"#, "host"])
    }

    func testTokenizeBackslashEscapeOutsideQuotes() throws {
        let tokens = try SSHCommandParser.tokenize(#"ssh user\ name@host"#)
        XCTAssertEqual(tokens, ["ssh", "user name@host"])
    }

    func testTokenizeUnterminatedQuoteThrows() {
        XCTAssertThrowsError(try SSHCommandParser.tokenize("ssh 'unterminated")) { error in
            XCTAssertEqual(error as? SSHCommandParser.ParseError, .unterminatedQuote)
        }
    }

    func testTokenizeEmptyThrows() {
        XCTAssertThrowsError(try SSHCommandParser.tokenize("   ")) { error in
            XCTAssertEqual(error as? SSHCommandParser.ParseError, .empty)
        }
    }

    // MARK: - Parse: plain ssh

    func testParsePlainSshUserAtHost() throws {
        let p = try SSHCommandParser.parse("ssh user@host")
        XCTAssertNil(p.sshExecutable)
        XCTAssertEqual(p.target, "user@host")
        XCTAssertEqual(p.extraArgs, [])
        XCTAssertFalse(p.skipDefaultOptions)
    }

    func testParseWithIdentityFile() throws {
        let p = try SSHCommandParser.parse(
            "ssh azureuser@4.151.241.30 -i ~/Downloads/pikapk3219_vps_key.pem"
        )
        XCTAssertEqual(p.target, "azureuser@4.151.241.30")
        XCTAssertEqual(p.extraArgs, ["-i", "~/Downloads/pikapk3219_vps_key.pem"])
        XCTAssertFalse(p.skipDefaultOptions)
        XCTAssertNil(p.sshExecutable)
    }

    func testParseDropsTtFlags() throws {
        let p = try SSHCommandParser.parse("ssh -t -tt user@host -p 22")
        XCTAssertEqual(p.target, "user@host")
        XCTAssertEqual(p.extraArgs, ["-p", "22"])
    }

    func testParseDropsTrailingRemoteCommand() throws {
        let p = try SSHCommandParser.parse("ssh user@host echo hello world")
        XCTAssertEqual(p.target, "user@host")
        XCTAssertEqual(p.extraArgs, [])
    }

    func testParseDropsAfterDoubleDash() throws {
        let p = try SSHCommandParser.parse("ssh -p 22 user@host -- some-remote-cmd")
        XCTAssertEqual(p.target, "user@host")
        XCTAssertEqual(p.extraArgs, ["-p", "22"])
    }

    func testParseAbsolutePathSshExecutable() throws {
        let p = try SSHCommandParser.parse("/opt/local/bin/ssh user@host")
        XCTAssertEqual(p.sshExecutable, "/opt/local/bin/ssh")
        XCTAssertEqual(p.target, "user@host")
    }

    func testParseMissingTargetThrows() {
        XCTAssertThrowsError(try SSHCommandParser.parse("ssh -p 22")) { error in
            XCTAssertEqual(error as? SSHCommandParser.ParseError, .missingTarget)
        }
    }

    func testParseMissingArgThrows() {
        XCTAssertThrowsError(try SSHCommandParser.parse("ssh -i")) { error in
            XCTAssertEqual(error as? SSHCommandParser.ParseError, .missingArg(option: "-i"))
        }
    }

    func testParseRejectsUnknownExecutable() {
        XCTAssertThrowsError(try SSHCommandParser.parse("rsync user@host"))
    }

    // MARK: - Parse: sshpass

    func testParseSshpassRealWorld() throws {
        let cmd = "sshpass -p '123qwe!@#' ssh -o ProxyCommand=\"/usr/local/bin/cloudflared access ssh --hostname objectives-automated-william-accordance.trycloudflare.com\" -o ServerAliveInterval=60 -o ServerAliveCountMax=5 -o TCPKeepAlive=yes -o StrictHostKeyChecking=no root@objectives-automated-william-accordance.trycloudflare.com -p 9022 -t 'export TERM=xterm-256color HOME=/home/appuser; source ~/.bashrc;'"
        let p = try SSHCommandParser.parse(cmd)
        XCTAssertEqual(p.sshExecutable, "sshpass")
        XCTAssertTrue(p.skipDefaultOptions)
        XCTAssertEqual(p.target, "root@objectives-automated-william-accordance.trycloudflare.com")
        // Inner ssh args should include the password capture, the inner
        // "ssh" token, all -o options, and -p 9022. -t and the trailing
        // remote command should be dropped.
        XCTAssertEqual(p.extraArgs[0], "-p")
        XCTAssertEqual(p.extraArgs[1], "123qwe!@#")
        XCTAssertEqual(p.extraArgs[2], "ssh")
        XCTAssertTrue(p.extraArgs.contains("ProxyCommand=/usr/local/bin/cloudflared access ssh --hostname objectives-automated-william-accordance.trycloudflare.com"))
        XCTAssertTrue(p.extraArgs.contains("StrictHostKeyChecking=no"))
        XCTAssertTrue(p.extraArgs.contains("9022"))
        XCTAssertFalse(p.extraArgs.contains("-t"))
        XCTAssertFalse(p.extraArgs.contains("-tt"))
        XCTAssertFalse(p.extraArgs.contains { $0.contains("xterm-256color") })
    }

    func testParseSshpassMinimal() throws {
        let p = try SSHCommandParser.parse("sshpass -p secret ssh root@x")
        XCTAssertEqual(p.sshExecutable, "sshpass")
        XCTAssertTrue(p.skipDefaultOptions)
        XCTAssertEqual(p.target, "root@x")
        XCTAssertEqual(p.extraArgs, ["-p", "secret", "ssh"])
    }
}

// MARK: - SSHCommandBuilder

final class SSHCommandBuilderTests: XCTestCase {

    func testBuildPlainSshInjectsDefaults() {
        let host = HerdrHost(
            id: UUID(),
            displayName: "n",
            transport: .sshStdio(target: "u@h"),
            sessionName: "s",
            addedAt: Date()
        )
        let inv = SSHCommandBuilder.build(for: host, remoteCommand: ["echo", "hi"])
        XCTAssertNotNil(inv)
        XCTAssertEqual(inv?.executable, "/usr/bin/ssh")
        let args = inv!.args
        // Default options injected.
        XCTAssertTrue(args.contains("-T"))
        XCTAssertTrue(args.contains("BatchMode=yes"))
        XCTAssertTrue(args.contains("ControlMaster=auto"))
        // Target appears, then "--", then remote command.
        let targetIdx = args.firstIndex(of: "u@h")!
        XCTAssertEqual(args[targetIdx + 1], "--")
        XCTAssertEqual(args[targetIdx + 2], "echo")
        XCTAssertEqual(args[targetIdx + 3], "hi")
    }

    func testBuildSkipsDefaultsWhenSkipFlagSet() {
        let host = HerdrHost(
            id: UUID(),
            displayName: "n",
            transport: .sshStdio(
                target: "u@h", extraArgs: [], skipDefaultOptions: true
            ),
            sessionName: "s",
            addedAt: Date()
        )
        let inv = SSHCommandBuilder.build(for: host, remoteCommand: [])!
        XCTAssertFalse(inv.args.contains("BatchMode=yes"))
        XCTAssertFalse(inv.args.contains("ControlMaster=auto"))
    }

    func testBuildSshpassInjectsAlwaysGoodAfterSshToken() {
        // sshpass extraArgs already contain the inner "ssh" token.
        // Defaults must be injected RIGHT AFTER that token, never before
        // sshpass itself.
        let host = HerdrHost(
            id: UUID(),
            displayName: "n",
            transport: .sshStdio(
                target: "root@x",
                extraArgs: ["-p", "pw", "ssh", "-o", "StrictHostKeyChecking=no"],
                skipDefaultOptions: true,
                sshExecutable: "/opt/homebrew/bin/sshpass"
            ),
            sessionName: "s",
            addedAt: Date()
        )
        let inv = SSHCommandBuilder.build(for: host, remoteCommand: [])!
        XCTAssertEqual(inv.executable, "/opt/homebrew/bin/sshpass")
        let args = inv.args
        // First two args still belong to sshpass.
        XCTAssertEqual(args[0], "-p")
        XCTAssertEqual(args[1], "pw")
        XCTAssertEqual(args[2], "ssh")
        // BatchMode must NOT be present (would block sshpass auth).
        XCTAssertFalse(args.contains("BatchMode=yes"))
        // ControlMaster must be injected after "ssh" token.
        XCTAssertTrue(args.contains("ControlMaster=auto"))
        // User's StrictHostKeyChecking=no must come after defaults.
        let cmIdx = args.firstIndex(of: "ControlMaster=auto")!
        let userOptIdx = args.firstIndex(of: "StrictHostKeyChecking=no")!
        XCTAssertLessThan(cmIdx, userOptIdx)
    }

    func testBuildReturnsNilForLocalUDS() {
        let host = HerdrHost.localhost(sessionName: "s")
        XCTAssertNil(SSHCommandBuilder.build(for: host, remoteCommand: []))
    }

    func testRemoteBinaryPathDefault() {
        let host = HerdrHost(
            id: UUID(),
            displayName: "n",
            transport: .sshStdio(target: "u@h"),
            sessionName: "s",
            addedAt: Date()
        )
        XCTAssertEqual(SSHCommandBuilder.remoteBinaryPath(for: host), "herdr-cmux")
    }

    func testRemoteBinaryPathOverride() {
        let host = HerdrHost(
            id: UUID(),
            displayName: "n",
            transport: .sshStdio(
                target: "u@h",
                remoteBinaryPath: "/opt/herdr/bin/herdr-cmux"
            ),
            sessionName: "s",
            addedAt: Date()
        )
        XCTAssertEqual(
            SSHCommandBuilder.remoteBinaryPath(for: host),
            "/opt/herdr/bin/herdr-cmux"
        )
    }

    func testIsSshpassWrapper() {
        XCTAssertTrue(SSHCommandBuilder.isSshpassWrapper("/usr/bin/sshpass"))
        XCTAssertTrue(SSHCommandBuilder.isSshpassWrapper("sshpass"))
        XCTAssertFalse(SSHCommandBuilder.isSshpassWrapper("/usr/bin/ssh"))
    }
}

// MARK: - Backwards-compat Codable

final class HerdrHostTransportCodableTests: XCTestCase {

    /// Old format had a synthesized enum coding with `_0` keyed payload.
    /// New format uses a struct with named keys. Both must decode.
    func testDecodesLegacyUnderscoreZeroFormat() throws {
        // {"sshStdio":{"_0":"user@host"}}
        let json = #"{"sshStdio":{"_0":"user@host"}}"#.data(using: .utf8)!
        let t = try JSONDecoder().decode(HerdrHost.Transport.self, from: json)
        guard case .sshStdio(let target, let extraArgs, let skip, let exe, let bin) = t else {
            return XCTFail("expected .sshStdio, got \(t)")
        }
        XCTAssertEqual(target, "user@host")
        XCTAssertEqual(extraArgs, [])
        XCTAssertFalse(skip)
        XCTAssertNil(exe)
        XCTAssertNil(bin)
    }

    func testDecodesNewStructFormat() throws {
        let json = #"""
        {"sshStdio":{"target":"u@h","extraArgs":["-i","key.pem"],"skipDefaultOptions":true,"sshExecutable":"/usr/bin/sshpass","remoteBinaryPath":"/opt/herdr-cmux"}}
        """#.data(using: .utf8)!
        let t = try JSONDecoder().decode(HerdrHost.Transport.self, from: json)
        guard case .sshStdio(let target, let extraArgs, let skip, let exe, let bin) = t else {
            return XCTFail("expected .sshStdio, got \(t)")
        }
        XCTAssertEqual(target, "u@h")
        XCTAssertEqual(extraArgs, ["-i", "key.pem"])
        XCTAssertTrue(skip)
        XCTAssertEqual(exe, "/usr/bin/sshpass")
        XCTAssertEqual(bin, "/opt/herdr-cmux")
    }

    func testRoundTripPreservesAllFields() throws {
        let original: HerdrHost.Transport = .sshStdio(
            target: "u@h",
            extraArgs: ["-i", "key.pem", "-p", "9022"],
            skipDefaultOptions: true,
            sshExecutable: "/usr/local/bin/sshpass",
            remoteBinaryPath: "~/.local/bin/herdr-cmux"
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(HerdrHost.Transport.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func testDecodesLocalUDS() throws {
        let json = #"{"localUDS":{}}"#.data(using: .utf8)!
        let t = try JSONDecoder().decode(HerdrHost.Transport.self, from: json)
        XCTAssertEqual(t, .localUDS)
    }
}
