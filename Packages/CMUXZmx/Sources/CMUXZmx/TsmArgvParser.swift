import Foundation

/// Detects `tsm attach <name>` / `tsm new <name>` invocations in a process's
/// argv. Used by `TsmBackend.parseAttachInvocation` to decide whether a
/// panel's foreground process is a tracked tsm session.
///
/// tsm exposes very few short aliases (only `p` for `palette`); attach/detach/
/// new/ls/kill all require their full names. The parser accepts only those.
public enum TsmArgvParser {
    public enum Subcommand: String, Sendable {
        case attach
        case new
    }

    public struct ParsedSession: Sendable, Equatable {
        public let sessionName: String
        public let subcommand: Subcommand
    }

    public static func parse(_ argv: [String]) -> ParsedSession? {
        guard let tsmIndex = firstTsmBinaryIndex(argv) else { return nil }
        var index = tsmIndex + 1
        // Skip global flags before the subcommand
        while index < argv.count, argv[index].hasPrefix("-") {
            index += 1
        }
        guard index < argv.count else { return nil }
        let sub: Subcommand
        switch argv[index] {
        case "attach": sub = .attach
        case "new": sub = .new
        default: return nil
        }
        index += 1
        var sessionName: String?
        while index < argv.count {
            let token = argv[index]
            if token == "--" {
                break
            }
            if token.hasPrefix("-") {
                index += 1
                continue
            }
            if sessionName == nil {
                sessionName = token
                index += 1
                continue
            }
            // First positional after the name is the command for `tsm new`;
            // both subcommands stop here.
            break
        }
        guard let name = sessionName, !name.isEmpty else { return nil }
        return ParsedSession(sessionName: name, subcommand: sub)
    }

    private static func firstTsmBinaryIndex(_ argv: [String]) -> Int? {
        for (i, token) in argv.enumerated() {
            let last = (token as NSString).lastPathComponent
            if last == "tsm" { return i }
        }
        return nil
    }
}
