import Foundation

public enum ZmxArgvParser {
    public enum Subcommand: String, Sendable {
        case attach
        case run

        static func from(_ token: String) -> Subcommand? {
            switch token {
            case "attach", "a": return .attach
            case "run", "r": return .run
            default: return nil
            }
        }
    }

    public struct ParsedSession: Sendable, Equatable {
        public let sessionName: String
        public let subcommand: Subcommand
        public let detached: Bool

        public init(sessionName: String, subcommand: Subcommand, detached: Bool = false) {
            self.sessionName = sessionName
            self.subcommand = subcommand
            self.detached = detached
        }
    }

    /// Detect a `zmx attach <name>` / `zmx run <name>` invocation in argv.
    /// Returns nil when the command is not a tracked zmx invocation.
    public static func parse(_ argv: [String]) -> ParsedSession? {
        guard let zmxIndex = firstZmxBinaryIndex(argv) else { return nil }
        var index = zmxIndex + 1
        // Skip global flags before subcommand
        while index < argv.count, argv[index].hasPrefix("-") {
            index += 1
        }
        guard index < argv.count else { return nil }
        guard let sub = Subcommand.from(argv[index]) else { return nil }
        index += 1

        var detached = false
        var sessionName: String?

        while index < argv.count {
            let token = argv[index]
            switch token {
            case "-d", "--detach":
                detached = true
                index += 1
            case "--fish":
                index += 1
            case "--":
                // remainder is the command for the session, stop parsing
                index = argv.count
            default:
                if token.hasPrefix("-") {
                    // Unknown flag, skip
                    index += 1
                } else if sessionName == nil {
                    sessionName = token
                    index += 1
                } else {
                    // first positional after session name is command, stop
                    index = argv.count
                }
            }
        }

        guard let name = sessionName, !name.isEmpty else { return nil }
        return ParsedSession(sessionName: name, subcommand: sub, detached: detached)
    }

    private static func firstZmxBinaryIndex(_ argv: [String]) -> Int? {
        for (i, token) in argv.enumerated() {
            let last = (token as NSString).lastPathComponent
            if last == "zmx" { return i }
        }
        return nil
    }
}
