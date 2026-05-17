import Foundation

/// Subprocess wrapper for the `tsm` CLI. Mirrors `ZmxClient` shape so the
/// `TsmBackend` adapter can stay thin. tsm has no `--json` output, so list
/// parsing is line-oriented; richer state lives in `tsm debug session`.
public struct TsmClient: Sendable {
    public let binaryPath: URL
    public let processTimeout: TimeInterval

    public init(binaryPath: URL, processTimeout: TimeInterval = 5.0) {
        self.binaryPath = binaryPath
        self.processTimeout = processTimeout
    }

    /// Plain-text `tsm ls`. Returns one entry per session; only the name is
    /// reliably extractable from the line.
    public func listSessionNames() throws -> [String] {
        let output = try runCapturing(arguments: ["ls"])
        return Self.parseListOutput(output)
    }

    public func isAlive(_ name: String) -> Bool {
        guard let names = try? listSessionNames() else { return false }
        return names.contains(name)
    }

    public func kill(_ names: [String], force: Bool = false) throws {
        guard !names.isEmpty else { return }
        var args = ["kill"]
        if force { args.append("-f") }
        args.append(contentsOf: names)
        _ = try runCapturing(arguments: args)
    }

    /// `tsm new <name> -- <cmd...>`. tsm creates the session and (per its
    /// docs) returns when the session is ready; we wait for completion so
    /// the caller knows the session exists before attaching.
    public func createSession(name: String, cmd: [String], dir: String?) throws {
        var args = ["new", name]
        if !cmd.isEmpty {
            args.append("--")
            args.append(contentsOf: cmd)
        }
        var env = ProcessInfo.processInfo.environment
        if let dir { env["PWD"] = dir }
        _ = try runCapturing(arguments: args, environment: env, currentDirectoryURL: dir.map { URL(fileURLWithPath: $0) })
    }

    public func detachSession(_ name: String) throws {
        _ = try runCapturing(arguments: ["detach", name])
    }

    public func renameSession(from old: String, to new: String) throws {
        _ = try runCapturing(arguments: ["rename", old, new])
    }

    public func debugSession(_ name: String) throws -> String {
        try runCapturing(arguments: ["debug", "session", name])
    }

    /// Worktree subcommands. `tsm wt add <branch>` etc. We don't try to
    /// parse the output; callers re-list afterwards if they need the new
    /// state.
    public func worktreeAdd(branch: String) throws {
        _ = try runCapturing(arguments: ["wt", "add", branch])
    }

    public func worktreeRemove(branch: String, force: Bool = false) throws {
        var args = ["wt", "rm", branch]
        if force { args.append("-f") }
        _ = try runCapturing(arguments: args)
    }

    public func worktreeSwitch(branch: String) throws {
        _ = try runCapturing(arguments: ["wt", branch])
    }

    public func worktreeList() throws -> String {
        try runCapturing(arguments: ["wt"])
    }

    // MARK: - parsing

    /// Strip ANSI escapes + whitespace, take the first non-empty token of
    /// each line as the session name. Tolerant of decorations tsm prints
    /// (●, ○, age suffixes).
    static func parseListOutput(_ text: String) -> [String] {
        let stripped = stripAnsi(text)
        return stripped
            .split(whereSeparator: { $0 == "\n" || $0 == "\r" })
            .compactMap { line -> String? in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { return nil }
                // tsm ls renders like "● editor  …" or just "editor".
                // Drop leading bullet glyphs.
                let cleaned = trimmed
                    .drop { "●○•".contains($0) }
                    .trimmingCharacters(in: .whitespaces)
                let head = cleaned.split(whereSeparator: { $0.isWhitespace }).first.map(String.init)
                guard let name = head, !name.isEmpty else { return nil }
                // Skip header rows tsm might print
                if name.lowercased() == "name" || name.lowercased() == "session" || name.lowercased() == "no" {
                    return nil
                }
                return name
            }
    }

    private static func stripAnsi(_ text: String) -> String {
        // CSI sequences: ESC [ <params> <final byte 0x40..0x7E>
        // OSC sequences: ESC ] ... BEL or ST (rare in tsm output)
        // Only strip when ESC is followed by [ or ] — otherwise it's a
        // standalone ESC and we drop just the ESC byte.
        var result = ""
        result.reserveCapacity(text.count)
        var iterator = text.unicodeScalars.makeIterator()
        while let scalar = iterator.next() {
            guard scalar.value == 0x1B else {
                result.unicodeScalars.append(scalar)
                continue
            }
            guard let intro = iterator.next() else { break }
            switch intro.value {
            case 0x5B, 0x9B: // CSI: '['
                while let next = iterator.next() {
                    if (0x40...0x7E).contains(next.value) { break }
                }
            case 0x5D: // OSC: ']'
                while let next = iterator.next() {
                    if next.value == 0x07 { break }
                    if next.value == 0x1B {
                        // ST sequence ESC \
                        if let after = iterator.next(), after.value == 0x5C {
                            break
                        }
                    }
                }
            default:
                // Drop the ESC + intro
                continue
            }
        }
        return result
    }

    // MARK: - subprocess

    private func runCapturing(
        arguments: [String],
        environment: [String: String]? = nil,
        currentDirectoryURL: URL? = nil
    ) throws -> String {
        let process = Process()
        process.executableURL = binaryPath
        process.arguments = arguments
        if let environment {
            process.environment = environment
        }
        if let currentDirectoryURL {
            process.currentDirectoryURL = currentDirectoryURL
        }
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()

        let deadline = Date().addingTimeInterval(processTimeout)
        while process.isRunning {
            if Date() > deadline {
                process.terminate()
                throw TsmClientError.timeout(arguments: arguments)
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        guard process.terminationStatus == 0 else {
            let errData = (try? stderr.fileHandleForReading.readToEnd()) ?? Data()
            let errText = String(data: errData, encoding: .utf8) ?? ""
            throw TsmClientError.nonZeroExit(
                status: process.terminationStatus,
                stderr: errText.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        let outData = (try? stdout.fileHandleForReading.readToEnd()) ?? Data()
        return String(data: outData, encoding: .utf8) ?? ""
    }
}

public enum TsmClientError: Error, Equatable {
    case timeout(arguments: [String])
    case nonZeroExit(status: Int32, stderr: String)
}
