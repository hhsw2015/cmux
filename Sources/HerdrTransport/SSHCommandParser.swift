import Foundation

/// Parses a pasted ssh / sshpass command string into the structured fields
/// `HerdrHost.Transport.sshStdio` needs. Supports POSIX shell quoting
/// (single quotes literal, double quotes literal-with-backslash, backslash
/// escapes outside quotes) and the common ssh option set.
///
/// Drops the trailing remote-command tokens (anything after `target` or
/// after `-t`/`-tt`) since cmux always replaces it with `herdr-cmux ...`.
enum SSHCommandParser {

    struct Parsed: Equatable {
        var sshExecutable: String?    // nil = use /usr/bin/ssh default
        var extraArgs: [String]       // args between executable and target
        var target: String            // user@host or alias
        var skipDefaultOptions: Bool  // sshpass case must skip BatchMode=yes
        var remoteBinaryPath: String? // not extracted from ssh; user can set
    }

    enum ParseError: Error, Equatable, LocalizedError {
        case empty
        case unterminatedQuote
        case unknownExecutable(String)
        case missingTarget
        case missingArg(option: String)

        var errorDescription: String? {
            switch self {
            case .empty: return "Command is empty"
            case .unterminatedQuote: return "Unterminated quote in command"
            case .unknownExecutable(let s): return "Unknown executable: \(s) (expected ssh or sshpass)"
            case .missingTarget: return "No SSH target found in command"
            case .missingArg(let opt): return "Option \(opt) requires an argument"
            }
        }
    }

    // MARK: - Public

    static func parse(_ command: String) throws -> Parsed {
        let tokens = try tokenize(command)
        return try parse(tokens: tokens)
    }

    static func tokenize(_ command: String) throws -> [String] {
        var out: [String] = []
        var current = ""
        var hasCurrent = false
        var i = command.startIndex
        let end = command.endIndex

        enum Mode { case normal, single, double }
        var mode: Mode = .normal

        func flush() {
            if hasCurrent {
                out.append(current)
                current = ""
                hasCurrent = false
            }
        }

        while i < end {
            let c = command[i]
            switch mode {
            case .normal:
                if c == "\\" {
                    let next = command.index(after: i)
                    if next < end {
                        current.append(command[next])
                        hasCurrent = true
                        i = command.index(after: next)
                        continue
                    } else {
                        i = next
                        continue
                    }
                } else if c == "'" {
                    mode = .single
                    hasCurrent = true
                } else if c == "\"" {
                    mode = .double
                    hasCurrent = true
                } else if c.isWhitespace {
                    flush()
                } else {
                    current.append(c)
                    hasCurrent = true
                }
            case .single:
                if c == "'" {
                    mode = .normal
                } else {
                    current.append(c)
                }
            case .double:
                if c == "\"" {
                    mode = .normal
                } else if c == "\\" {
                    let next = command.index(after: i)
                    if next < end {
                        let esc = command[next]
                        if esc == "\"" || esc == "\\" || esc == "$" || esc == "`" || esc == "\n" {
                            current.append(esc)
                        } else {
                            current.append(c)
                            current.append(esc)
                        }
                        i = command.index(after: next)
                        continue
                    }
                } else {
                    current.append(c)
                }
            }
            i = command.index(after: i)
        }

        if mode != .normal { throw ParseError.unterminatedQuote }
        flush()
        if out.isEmpty { throw ParseError.empty }
        return out
    }

    // MARK: - Token walk

    /// ssh single-letter options that take an argument. From `man ssh(1)`.
    private static let sshOptionsTakingArg: Set<String> = [
        "-b", "-c", "-D", "-E", "-e", "-F", "-I", "-i", "-J", "-L",
        "-l", "-m", "-O", "-o", "-p", "-Q", "-R", "-S", "-W", "-w",
    ]

    /// sshpass options. `-p PWD`, `-f FILE`, `-d FD` take args; `-e`, `-v` don't.
    private static let sshpassOptionsTakingArg: Set<String> = ["-p", "-f", "-d", "-P"]

    static func parse(tokens initial: [String]) throws -> Parsed {
        var tokens = initial
        guard !tokens.isEmpty else { throw ParseError.empty }

        var sshExecutable: String?
        var extraArgs: [String] = []
        var skipDefaultOptions = false

        let head = tokens.removeFirst()
        let headBase = (head as NSString).lastPathComponent

        if headBase == "sshpass" {
            // sshpass <sshpass-opts> ssh <ssh-opts> target
            sshExecutable = head
            skipDefaultOptions = true
            // Capture sshpass own args until we hit the inner ssh
            while !tokens.isEmpty {
                let t = tokens[0]
                if (t as NSString).lastPathComponent == "ssh" {
                    extraArgs.append(t)  // keep "ssh" as first arg to sshpass
                    tokens.removeFirst()
                    break
                }
                if sshpassOptionsTakingArg.contains(t) {
                    extraArgs.append(t)
                    tokens.removeFirst()
                    if tokens.isEmpty { throw ParseError.missingArg(option: t) }
                    extraArgs.append(tokens.removeFirst())
                } else {
                    extraArgs.append(t)
                    tokens.removeFirst()
                }
            }
        } else if headBase == "ssh" {
            if head != "ssh" { sshExecutable = head }  // absolute path
        } else {
            throw ParseError.unknownExecutable(head)
        }

        // Now walk ssh options. First non-option positional = target;
        // anything after target = remote command, drop.
        var target: String?
        while !tokens.isEmpty {
            let t = tokens.removeFirst()
            if t == "-t" || t == "-tt" || t == "-T" {
                // -t/-tt force tty (we don't want), -T disables (we already
                // add it). Drop. Don't consume an argument.
                continue
            }
            if t == "--" {
                // Everything after is the remote command. Drop entirely;
                // cmux supplies its own.
                break
            }
            if sshOptionsTakingArg.contains(t) {
                guard !tokens.isEmpty else { throw ParseError.missingArg(option: t) }
                let arg = tokens.removeFirst()
                extraArgs.append(t)
                extraArgs.append(arg)
                continue
            }
            if t.hasPrefix("-") && t.count >= 2 {
                // -i/path style (option glued to value) e.g. "-p9022"
                // Not strictly POSIX for ssh but accept for robustness.
                let optChar = "-" + String(t[t.index(after: t.startIndex)])
                if sshOptionsTakingArg.contains(optChar) && t.count > 2 {
                    extraArgs.append(t)
                    continue
                }
                // Combined flags or unknown — pass through as-is.
                extraArgs.append(t)
                continue
            }
            // First positional = target.
            target = t
            break
        }

        guard let resolvedTarget = target else { throw ParseError.missingTarget }

        return Parsed(
            sshExecutable: sshExecutable,
            extraArgs: extraArgs,
            target: resolvedTarget,
            skipDefaultOptions: skipDefaultOptions,
            remoteBinaryPath: nil
        )
    }
}
