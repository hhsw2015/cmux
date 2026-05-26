import Foundation
import CMUXAgentLaunch

nonisolated enum TerminalStartupShellQuoting {
    static func singleQuoted(_ value: String) -> String {
        if value.utf8.contains(where: { $0 >= 0x80 }) {
            return asciiPrintfCommandSubstitution(for: value)
        }
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func shellToken(_ value: String, allowingBareASCII: Bool) -> String {
        if value.utf8.contains(where: { $0 >= 0x80 }) {
            return asciiPrintfCommandSubstitution(for: value)
        }
        if allowingBareASCII,
           value.range(of: "[^A-Za-z0-9_./:=+-]", options: .regularExpression) == nil {
            return value
        }
        return singleQuoted(value)
    }

    private static func asciiPrintfCommandSubstitution(for value: String) -> String {
        let octalBytes = value.utf8
            .map { String(format: #"\%03o"#, Int($0)) }
            .joined()
        return #""$(printf '"# + octalBytes + #"')""#
    }
}

fileprivate func shellSingleQuoted(_ value: String) -> String {
    TerminalStartupShellQuoting.singleQuoted(value)
}

enum AgentResumeCommandBuilder {
    private static let claudeAuthSelectionEnvironmentKeys: Set<String> = [
        "ANTHROPIC_API_KEY",
        "ANTHROPIC_AUTH_TOKEN",
        "ANTHROPIC_BASE_URL",
        "ANTHROPIC_MODEL",
        "ANTHROPIC_SMALL_FAST_MODEL",
        "CLAUDE_CODE_USE_BEDROCK",
        "CLAUDE_CODE_USE_VERTEX",
        "CLAUDE_CONFIG_DIR"
    ]
    static func resumeShellCommand(
        kind: RestorableAgentKind,
        sessionId: String,
        launchCommand: AgentLaunchCommandSnapshot?,
        workingDirectory: String?,
        registrationOverride: CmuxVaultAgentRegistration? = nil,
        includeWorkingDirectoryPrefix: Bool = true
    ) -> String? {
        let customRegistration = registrationOverride
        guard !sessionId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let argv = resumeArguments(
                  kind: kind,
                  sessionId: sessionId,
                  launchCommand: launchCommand,
                  workingDirectory: workingDirectory,
                  customRegistration: customRegistration
              ),
              !argv.isEmpty else {
            return nil
        }

        return shellCommand(
            argv: argv,
            kind: kind,
            launchCommand: launchCommand,
            workingDirectory: workingDirectory,
            customRegistration: customRegistration,
            includeWorkingDirectoryPrefix: includeWorkingDirectoryPrefix
        )
    }

    static func forkShellCommand(
        kind: RestorableAgentKind,
        sessionId: String,
        launchCommand: AgentLaunchCommandSnapshot?,
        workingDirectory: String?,
        registrationOverride: CmuxVaultAgentRegistration? = nil,
        includeWorkingDirectoryPrefix: Bool = true
    ) -> String? {
        let customRegistration = registrationOverride
        guard !sessionId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let argv = forkArguments(
                  kind: kind,
                  sessionId: sessionId,
                  launchCommand: launchCommand
              ),
              !argv.isEmpty else {
            return nil
        }

        return shellCommand(
            argv: argv,
            kind: kind,
            launchCommand: launchCommand,
            workingDirectory: workingDirectory,
            customRegistration: customRegistration,
            includeWorkingDirectoryPrefix: includeWorkingDirectoryPrefix
        )
    }

    private static func shellCommand(
        argv: [String],
        kind: RestorableAgentKind,
        launchCommand: AgentLaunchCommandSnapshot?,
        workingDirectory: String?,
        customRegistration: CmuxVaultAgentRegistration?,
        includeWorkingDirectoryPrefix: Bool
    ) -> String? {
        var commandParts: [String] = []
        let environmentParts = launchEnvironmentParts(kind: kind, environment: launchCommand?.environment)
        // Use inline shell variable assignment (VAR=val cmd) instead of `env VAR=val cmd`.
        // `env` bypasses shell functions, but inline assignment preserves them,
        // which is needed for wrappers like the claude() shell function.
        commandParts.append(contentsOf: argv)

        var shellCommand: String
        if !environmentParts.isEmpty {
            // Format as KEY='value' (not 'KEY=value') so shell treats it as env assignment
            let envPrefix = environmentParts.map { part -> String in
                if let eqIdx = part.firstIndex(of: "=") {
                    let key = String(part[..<eqIdx])
                    let value = String(part[part.index(after: eqIdx)...])
                    return "\(key)=\(shellSingleQuoted(value))"
                }
                return shellSingleQuoted(part)
            }.joined(separator: " ")
            let cmdSuffix = commandParts.map(shellSingleQuoted).joined(separator: " ")
            shellCommand = "\(envPrefix) \(cmdSuffix)"
        } else {
            shellCommand = commandParts.map(shellSingleQuoted).joined(separator: " ")
        }
        let cwd = !includeWorkingDirectoryPrefix || customRegistration?.cwd == .ignore
            ? nil
            : normalized(workingDirectory ?? launchCommand?.workingDirectory)
        if let cwd {
            // Don't resume into a dead working directory. The captured `cd`
            // would fail at restore time, `&&` would short-circuit before the
            // agent runs, and the user would see a dead "no such file or
            // directory" prompt with no way back. Returning nil tells the
            // caller (`resumeStartupInput`) to skip auto-resume entirely so
            // the panel opens as a fresh shell instead.
            guard FileManager.default.fileExists(atPath: cwd) else { return nil }
            shellCommand = "cd \(shellSingleQuoted(cwd)) && \(shellCommand)"
        }
        return shellCommand
    }

    static func openCodeVersionProbe(
        launchCommand: AgentLaunchCommandSnapshot?
    ) -> (executable: String, arguments: [String])? {
        switch launchCommand?.launcher {
        case "omo":
            return nil
        case "omx", "omc":
            return nil
        default:
            let original = commandParts(launchCommand: launchCommand, fallbackExecutable: "opencode")
            return (original.executable, ["--version"])
        }
    }

    private static func launchEnvironmentParts(
        kind: RestorableAgentKind,
        environment: [String: String]?
    ) -> [String] {
        guard let environment, !environment.isEmpty else {
            return []
        }

        var environmentParts: [String] = []
        var preservedClaudeAuthSelectionEnvironmentKeys: [String] = []
        let selectedEnvironment = AgentLaunchEnvironmentPolicy.selectedEnvironment(from: environment)
        for key in selectedEnvironment.keys.sorted() {
            guard let value = selectedEnvironment[key] else { continue }
            environmentParts.append("\(key)=\(value)")
            if kind == .claude,
               claudeAuthSelectionEnvironmentKeys.contains(key) {
                preservedClaudeAuthSelectionEnvironmentKeys.append(key)
            }
        }
        if !preservedClaudeAuthSelectionEnvironmentKeys.isEmpty {
            environmentParts.append("CMUX_PRESERVE_CLAUDE_AUTH_SELECTION_ENV=1")
            environmentParts.append(
                "CMUX_PRESERVE_CLAUDE_AUTH_SELECTION_ENV_KEYS=\(preservedClaudeAuthSelectionEnvironmentKeys.joined(separator: ","))"
            )
        }
        return environmentParts
    }

    private static func resumeArguments(
        kind: RestorableAgentKind,
        sessionId: String,
        launchCommand: AgentLaunchCommandSnapshot?,
        workingDirectory: String?,
        customRegistration: CmuxVaultAgentRegistration?
    ) -> [String]? {
        switch launchCommand?.launcher {
        case "claudeTeams":
            let original = commandParts(
                launchCommand: launchCommand,
                fallbackExecutable: "cmux"
            )
            var args = original.tail
            if args.first == "claude-teams" {
                args.removeFirst()
            }
            guard let preserved = AgentLaunchSanitizer.preservedArguments(kind: "claude", args: args) else { return nil }
            return [original.executable, "claude-teams", "--resume", sessionId] + preserved
        case "codexTeams":
            let original = commandParts(
                launchCommand: launchCommand,
                fallbackExecutable: "cmux"
            )
            var args = original.tail
            if args.first == "codex-teams" {
                args.removeFirst()
            }
            guard let preserved = AgentLaunchSanitizer.preservedCodexForkArguments(args: args) else { return nil }
            return [original.executable, "codex-teams", "resume", sessionId] + preserved
        case "omo":
            let original = commandParts(
                launchCommand: launchCommand,
                fallbackExecutable: "cmux"
            )
            var args = original.tail
            if args.first == "omo" {
                args.removeFirst()
            }
            guard let preserved = AgentLaunchSanitizer.preservedArguments(kind: "opencode", args: args) else { return nil }
            return [original.executable, "omo", "--session", sessionId] + preserved
        case "omx", "omc":
            return nil
        default:
            break
        }

        if case .custom = kind {
            guard let customRegistration else { return nil }
            if customRegistration.id == CmuxVaultAgentRegistration.builtInAntigravity.id {
                return resumeWithOption(
                    kind: "antigravity",
                    launchCommand: launchCommand,
                    fallbackExecutable: customRegistration.defaultExecutable,
                    option: "--conversation",
                    sessionId: sessionId
                )
            }
            let arguments = customResumeArguments(
                registration: customRegistration,
                sessionId: sessionId,
                launchCommand: launchCommand,
                workingDirectory: workingDirectory
            )
            return arguments.isEmpty ? nil : arguments
        }

        switch kind {
        case .claude:
            return resumeWithOption(
                kind: "claude",
                launchCommand: launchCommand,
                fallbackExecutable: "claude",
                option: "--resume",
                sessionId: sessionId
            )
        case .codex:
            let original = commandParts(launchCommand: launchCommand, fallbackExecutable: "codex")
            guard let preserved = AgentLaunchSanitizer.preservedCodexForkArguments(args: original.tail) else { return nil }
            return [original.executable, "resume", sessionId] + preserved
        case .grok:
            return resumeWithOption(
                kind: "grok",
                launchCommand: launchCommand,
                fallbackExecutable: "grok",
                option: "-r",
                sessionId: sessionId
            )
        case .pi:
            return resumeWithOption(
                kind: "pi",
                launchCommand: launchCommand,
                fallbackExecutable: "pi",
                option: "--session",
                sessionId: sessionId
            )
        case .amp:
            let original = commandParts(launchCommand: launchCommand, fallbackExecutable: "amp")
            guard let preserved = AgentLaunchSanitizer.preservedArguments(kind: "amp", args: original.tail) else { return nil }
            return [original.executable, "threads", "continue"] + preserved + [sessionId]
        case .cursor:
            return resumeWithOption(
                kind: "cursor",
                launchCommand: launchCommand,
                fallbackExecutable: "cursor-agent",
                option: "--resume",
                sessionId: sessionId
            )
        case .gemini:
            return resumeWithOption(
                kind: "gemini",
                launchCommand: launchCommand,
                fallbackExecutable: "gemini",
                option: "--resume",
                sessionId: sessionId
            )
        case .antigravity:
            return resumeWithOption(
                kind: "antigravity",
                launchCommand: launchCommand,
                fallbackExecutable: "agy",
                option: "--conversation",
                sessionId: sessionId
            )
        case .opencode:
            let original = commandParts(launchCommand: launchCommand, fallbackExecutable: "opencode")
            guard let preserved = AgentLaunchSanitizer.preservedArguments(kind: "opencode", args: original.tail) else { return nil }
            return [original.executable, "--session", sessionId] + preserved
        case .rovodev:
            let original = commandParts(launchCommand: launchCommand, fallbackExecutable: "acli")
            guard let preserved = AgentLaunchSanitizer.preservedArguments(kind: "rovodev", args: original.tail) else { return nil }
            return [original.executable, "rovodev", "run", "--restore", sessionId] + preserved
        case .hermesAgent:
            let original = commandParts(launchCommand: launchCommand, fallbackExecutable: "hermes")
            guard let preserved = AgentLaunchSanitizer.preservedArguments(kind: "hermes-agent", args: original.tail) else { return nil }
            return [original.executable] + preserved + ["--resume", sessionId]
        case .copilot:
            return resumeWithOption(
                kind: "copilot",
                launchCommand: launchCommand,
                fallbackExecutable: "copilot",
                option: "--resume",
                sessionId: sessionId
            )
        case .codebuddy:
            return resumeWithOption(
                kind: "codebuddy",
                launchCommand: launchCommand,
                fallbackExecutable: "codebuddy",
                option: "--resume",
                sessionId: sessionId
            )
        case .factory:
            return resumeWithOption(
                kind: "factory",
                launchCommand: launchCommand,
                fallbackExecutable: "droid",
                option: "--resume",
                sessionId: sessionId
            )
        case .qoder:
            return resumeWithOption(
                kind: "qoder",
                launchCommand: launchCommand,
                fallbackExecutable: "qodercli",
                option: "--resume",
                sessionId: sessionId
            )
        case .custom:
            return nil
        }
    }

    private static func forkArguments(
        kind: RestorableAgentKind,
        sessionId: String,
        launchCommand: AgentLaunchCommandSnapshot?
    ) -> [String]? {
        switch launchCommand?.launcher {
        case "claudeTeams":
            let original = commandParts(
                launchCommand: launchCommand,
                fallbackExecutable: "cmux"
            )
            var args = original.tail
            if args.first == "claude-teams" {
                args.removeFirst()
            }
            guard let preserved = AgentLaunchSanitizer.preservedArguments(kind: "claude", args: args) else { return nil }
            return [original.executable, "claude-teams", "--resume", sessionId, "--fork-session"] + preserved
        case "codexTeams":
            let original = commandParts(
                launchCommand: launchCommand,
                fallbackExecutable: "cmux"
            )
            var args = original.tail
            if args.first == "codex-teams" {
                args.removeFirst()
            }
            guard let preserved = AgentLaunchSanitizer.preservedCodexForkArguments(args: args) else { return nil }
            return [original.executable, "codex-teams", "fork", sessionId] + preserved
        case "omo":
            let original = commandParts(
                launchCommand: launchCommand,
                fallbackExecutable: "cmux"
            )
            var args = original.tail
            if args.first == "omo" {
                args.removeFirst()
            }
            guard let preserved = AgentLaunchSanitizer.preservedArguments(kind: "opencode", args: args) else { return nil }
            return [original.executable, "omo", "--session", sessionId, "--fork"] + preserved
        case "omx", "omc":
            return nil
        default:
            break
        }

        switch kind {
        case .claude:
            let original = commandParts(launchCommand: launchCommand, fallbackExecutable: "claude")
            guard let preserved = AgentLaunchSanitizer.preservedArguments(kind: "claude", args: original.tail) else { return nil }
            return [original.executable, "--resume", sessionId, "--fork-session"] + preserved
        case .codex:
            let original = commandParts(launchCommand: launchCommand, fallbackExecutable: "codex")
            guard let preserved = AgentLaunchSanitizer.preservedCodexForkArguments(args: original.tail) else { return nil }
            return [original.executable, "fork", sessionId] + preserved
        case .opencode:
            let original = commandParts(launchCommand: launchCommand, fallbackExecutable: "opencode")
            guard let preserved = AgentLaunchSanitizer.preservedArguments(kind: "opencode", args: original.tail) else { return nil }
            return [original.executable, "--session", sessionId, "--fork"] + preserved
        default:
            return nil
        }
    }

    private static func customResumeArguments(
        registration: CmuxVaultAgentRegistration,
        sessionId: String,
        launchCommand: AgentLaunchCommandSnapshot?,
        workingDirectory: String?
    ) -> [String] {
        let templateParts = splitShellWords(registration.resumeCommand)
        guard !templateParts.isEmpty else { return [] }
        let original = commandParts(
            launchCommand: launchCommand,
            fallbackExecutable: registration.defaultExecutable
        )
        let sessionDirectory = normalized(registration.sessionDirectory).map {
            ($0 as NSString).expandingTildeInPath
        }
        let replacements: [String: String] = [
            "sessionId": sessionId,
            "sessionPath": sessionId,
            "executable": original.executable,
            "cwd": normalized(workingDirectory ?? launchCommand?.workingDirectory) ?? "",
            "sessionDir": sessionDirectory ?? "",
        ]
        var resolved: [String] = []
        for part in templateParts {
            guard let value = resolveTemplatePart(part, replacements: replacements) else { return [] }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return [] }
            resolved.append(trimmed)
        }
        return resolved
    }

    private static func resolveTemplatePart(
        _ part: String,
        replacements: [String: String]
    ) -> String? {
        var resolved = ""
        var searchStart = part.startIndex
        while let opening = part[searchStart...].range(of: "{{") {
            resolved.append(contentsOf: part[searchStart..<opening.lowerBound])
            guard let closing = part[opening.upperBound...].range(of: "}}") else {
                resolved.append(contentsOf: part[opening.lowerBound...])
                return resolved
            }
            let key = String(part[opening.upperBound..<closing.lowerBound])
            if let replacement = replacements[key] {
                if replacement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return nil
                }
                resolved += replacement
            } else {
                resolved.append(contentsOf: part[opening.lowerBound..<closing.upperBound])
            }
            searchStart = closing.upperBound
        }
        resolved.append(contentsOf: part[searchStart...])
        return resolved
    }

    private static func splitShellWords(_ command: String) -> [String] {
        enum Quote {
            case single
            case double
        }

        var words: [String] = []
        var current = ""
        var quote: Quote?
        var escaping = false

        func finishWord() {
            guard !current.isEmpty else { return }
            words.append(current)
            current = ""
        }

        for character in command {
            if escaping {
                current.append(character)
                escaping = false
                continue
            }
            if character == "\\" {
                escaping = true
                continue
            }
            switch (quote, character) {
            case (.single, "'"), (.double, "\""):
                quote = nil
            case (nil, "'"):
                quote = .single
            case (nil, "\""):
                quote = .double
            case (nil, " "), (nil, "\t"), (nil, "\n"):
                finishWord()
            default:
                current.append(character)
            }
        }
        if escaping {
            current.append("\\")
        }
        finishWord()
        return words
    }

    private static func resumeWithOption(
        kind: String,
        launchCommand: AgentLaunchCommandSnapshot?,
        fallbackExecutable: String,
        option: String,
        sessionId: String
    ) -> [String]? {
        let original = commandParts(launchCommand: launchCommand, fallbackExecutable: fallbackExecutable)
        guard let preserved = AgentLaunchSanitizer.preservedArguments(kind: kind, args: original.tail) else {
            return nil
        }
        // Use the bare command name (fallbackExecutable) instead of the absolute
        // binary path. This allows shell functions/aliases to intercept the call,
        // which is needed for wrappers that add flags like --append-system-prompt-file.
        let executable = fallbackExecutable
        return [executable, option, sessionId] + preserved
    }

    private static func commandParts(
        launchCommand: AgentLaunchCommandSnapshot?,
        fallbackExecutable: String
    ) -> (executable: String, tail: [String]) {
        let arguments = launchCommand?.arguments ?? []
        let executable = normalized(launchCommand?.executablePath)
            ?? arguments.first
            ?? fallbackExecutable
        let tail = arguments.isEmpty ? [] : Array(arguments.dropFirst())
        return (executable, tail)
    }

    private static func normalized(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}

struct SessionRestorableAgentSnapshot: Codable, Sendable {
    static let maxInlineStartupInputBytes = 900

    var kind: RestorableAgentKind
    var sessionId: String
    var workingDirectory: String?
    var launchCommand: AgentLaunchCommandSnapshot?
    var registration: CmuxVaultAgentRegistration? = nil

    var resumeCommand: String? {
        AgentResumeCommandBuilder.resumeShellCommand(
            kind: kind,
            sessionId: sessionId,
            launchCommand: launchCommand,
            workingDirectory: workingDirectory,
            registrationOverride: registration
        )
    }

    var forkCommand: String? {
        AgentResumeCommandBuilder.forkShellCommand(
            kind: kind,
            sessionId: sessionId,
            launchCommand: launchCommand,
            workingDirectory: workingDirectory,
            registrationOverride: registration
        )
    }

    func resumeStartupInput(
        fileManager: FileManager = .default,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory
    ) -> String? {
        startupInput(
            command: resumeCommand,
            fileManager: fileManager,
            temporaryDirectory: temporaryDirectory
        )
    }

    func forkStartupInput(
        fileManager: FileManager = .default,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory,
        allowLauncherScript: Bool = true
    ) -> String? {
        startupInput(
            command: forkCommand,
            fileManager: fileManager,
            temporaryDirectory: temporaryDirectory,
            allowLauncherScript: allowLauncherScript
        )
    }

    private func startupInput(
        command: String?,
        fileManager: FileManager,
        temporaryDirectory: URL,
        allowLauncherScript: Bool = true
    ) -> String? {
        guard let command else { return nil }
        let inlineInput = command + "\n"
        guard !Self.canUseInlineStartupInput(inlineInput) else {
            return inlineInput
        }
        guard allowLauncherScript else { return nil }
        guard let scriptURL = AgentResumeScriptStore.writeLauncherScript(
            command: command,
            kind: kind,
            sessionId: sessionId,
            fileManager: fileManager,
            temporaryDirectory: temporaryDirectory
        ) else {
            return nil
        }

        guard let scriptInput = Self.launcherStartupInput(for: scriptURL) else {
            try? fileManager.removeItem(at: scriptURL)
            return nil
        }
        return scriptInput
    }

    private static func launcherStartupInput(for scriptURL: URL) -> String? {
        let directInput = "/bin/zsh \(shellSingleQuoted(scriptURL.path))\n"
        if canUseInlineStartupInput(directInput) {
            return directInput
        }

        let encodedPath = Data(scriptURL.path.utf8).base64EncodedString()
        let decodeCommand = """
        cmux_agent_resume_script="$(printf '%s' \(shellSingleQuoted(encodedPath)) | base64 --decode 2>/dev/null || printf '%s' \(shellSingleQuoted(encodedPath)) | base64 -D 2>/dev/null)"; exec /bin/zsh "$cmux_agent_resume_script"
        """
        let encodedInput = "/bin/zsh -c \(shellSingleQuoted(decodeCommand))\n"
        return canUseInlineStartupInput(encodedInput) ? encodedInput : nil
    }

    private static func canUseInlineStartupInput(_ input: String) -> Bool {
        guard input.utf8.count <= Self.maxInlineStartupInputBytes else { return false }
        // Ghostty embedded startup input is parsed as escaped Zig string content.
        // Keep inline transport ASCII-only so UTF-8 restore commands stay byte-exact in the launcher script.
        return input.utf8.allSatisfy { $0 < 0x80 }
    }
}

extension SessionRestorableAgentSnapshot {
    var agentDisplayName: String {
        if let name = registration?.name.trimmingCharacters(in: .whitespacesAndNewlines),
           !name.isEmpty {
            return name
        }
        return kind.displayName
    }
}

private enum AgentResumeScriptStore {
    private static let directoryName = "cmux-agent-resume"
    private static let scriptTTL: TimeInterval = 24 * 60 * 60

    static func writeLauncherScript(
        command: String,
        kind: RestorableAgentKind,
        sessionId: String,
        fileManager: FileManager,
        temporaryDirectory: URL
    ) -> URL? {
        let directoryURL = temporaryDirectory.appendingPathComponent(directoryName, isDirectory: true)
        do {
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directoryURL.path)
            pruneOldScripts(in: directoryURL, fileManager: fileManager)

            let safeSessionPrefix = sessionId
                .prefix(12)
                .map { character -> Character in
                    character.isLetter || character.isNumber || character == "-" ? character : "_"
                }
            let scriptURL = directoryURL.appendingPathComponent(
                "\(kind.rawValue)-\(String(safeSessionPrefix))-\(UUID().uuidString).zsh",
                isDirectory: false
            )
            let contents = """
            #!/bin/zsh
            rm -f -- "$0" 2>/dev/null || true
            \(command)
            """
            try contents.write(to: scriptURL, atomically: true, encoding: .utf8)
            try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: scriptURL.path)
            return scriptURL
        } catch {
            return nil
        }
    }

    private static func pruneOldScripts(in directoryURL: URL, fileManager: FileManager) {
        guard let scriptURLs = try? fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        let cutoff = Date().addingTimeInterval(-scriptTTL)
        for scriptURL in scriptURLs where scriptURL.pathExtension == "zsh" {
            let values = try? scriptURL.resourceValues(forKeys: [.contentModificationDateKey])
            if let modified = values?.contentModificationDate, modified < cutoff {
                try? fileManager.removeItem(at: scriptURL)
            }
        }
    }
}

private struct RestorableAgentHookSessionRecord: Codable, Sendable {
    var sessionId: String
    var workspaceId: String
    var surfaceId: String
    var cwd: String?
    var transcriptPath: String?
    var pid: Int?
    var launchCommand: AgentLaunchCommandSnapshot?
    var isRestorable: Bool?
    var agentLifecycle: AgentHibernationLifecycleState?
    var updatedAt: TimeInterval
}

private struct RestorableAgentHookSessionStoreFile: Codable, Sendable {
    var version: Int = 1
    var sessions: [String: RestorableAgentHookSessionRecord] = [:]
}

struct RestorableAgentSessionIndex: Sendable {
    static let empty = RestorableAgentSessionIndex(entriesByPanel: [:])

    struct PanelKey: Hashable, Sendable {
        let workspaceId: UUID
        let panelId: UUID
    }

    struct Entry: Sendable {
        let snapshot: SessionRestorableAgentSnapshot
        let lifecycle: AgentHibernationLifecycleState?
        let updatedAt: TimeInterval
        let processIDs: Set<Int>
    }

    private struct SessionKey: Hashable {
        let kind: RestorableAgentKind
        let sessionId: String
    }

    private let entriesByPanel: [PanelKey: Entry]
    // Workspace UUIDs are regenerated on every cmux launch, so a hook record
    // saved as (workspaceA, panelA) won't match a lookup with (workspaceB, panelA)
    // after relaunch even though it's the same panel. Panel UUIDs (== surface IDs
    // == CMUX_SURFACE_ID) are stable per snapshot save and unique enough across
    // the hook records, so this fallback recovers the agent for that panel.
    private let entriesByPanelId: [UUID: Entry]

    private func entry(workspaceId: UUID, panelId: UUID) -> Entry? {
        entriesByPanel[PanelKey(workspaceId: workspaceId, panelId: panelId)] ?? entriesByPanelId[panelId]
    }

    func snapshot(workspaceId: UUID, panelId: UUID) -> SessionRestorableAgentSnapshot? {
        entry(workspaceId: workspaceId, panelId: panelId)?.snapshot
    }

    func lifecycle(workspaceId: UUID, panelId: UUID) -> AgentHibernationLifecycleState? {
        entry(workspaceId: workspaceId, panelId: panelId)?.lifecycle
    }

    func updatedAt(workspaceId: UUID, panelId: UUID) -> TimeInterval? {
        entry(workspaceId: workspaceId, panelId: panelId)?.updatedAt
    }

    func processIDs(workspaceId: UUID, panelId: UUID) -> Set<Int> {
        entry(workspaceId: workspaceId, panelId: panelId)?.processIDs ?? []
    }

    func hasLiveProcess(workspaceId: UUID, panelId: UUID) -> Bool {
        !processIDs(workspaceId: workspaceId, panelId: panelId).isEmpty
    }

    static func load(
        homeDirectory: String = NSHomeDirectory(),
        fileManager: FileManager = .default
    ) -> RestorableAgentSessionIndex {
        let registry = CmuxVaultAgentRegistry.load(homeDirectory: homeDirectory, fileManager: fileManager)
        return load(
            homeDirectory: homeDirectory,
            fileManager: fileManager,
            registry: registry,
            detectedSnapshots: [:]
        )
    }

    static func loadIncludingProcessDetectedSnapshots(
        homeDirectory: String = NSHomeDirectory(),
        fileManager: FileManager = .default
    ) async -> RestorableAgentSessionIndex {
        await Task.detached(priority: .utility) {
            loadIncludingProcessDetectedSnapshotsSynchronously(
                homeDirectory: homeDirectory,
                fileManager: fileManager
            )
        }.value
    }

    static func loadIncludingProcessDetectedSnapshotsSynchronously(
        homeDirectory: String = NSHomeDirectory(),
        fileManager: FileManager = .default
    ) -> RestorableAgentSessionIndex {
        let registry = CmuxVaultAgentRegistry.load(homeDirectory: homeDirectory, fileManager: fileManager)
        let detectedSnapshots = processDetectedSnapshots(
            registry: registry,
            fileManager: fileManager
        )
        return load(
            homeDirectory: homeDirectory,
            fileManager: fileManager,
            registry: registry,
            detectedSnapshots: detectedSnapshots
        )
    }

    static func load(
        homeDirectory: String,
        fileManager: FileManager,
        registry: CmuxVaultAgentRegistry,
        detectedSnapshots: [PanelKey: (snapshot: SessionRestorableAgentSnapshot, updatedAt: TimeInterval, processIDs: Set<Int>)],
        processArgumentsProvider: (Int) -> CmuxTopProcessArguments? = {
            CmuxTopProcessSnapshot.processArgumentsAndEnvironment(for: $0)
        }
    ) -> RestorableAgentSessionIndex {
        let decoder = JSONDecoder()
        var resolved: [PanelKey: Entry] = [:]
        let claudeTranscriptLookup = ClaudeTranscriptLookupCache(
            homeDirectory: homeDirectory,
            fileManager: fileManager
        )
        let builtInKindIDs = Set(RestorableAgentKind.allCases.map(\.rawValue))
        let hookKinds: [(kind: RestorableAgentKind, registration: CmuxVaultAgentRegistration?)] =
            RestorableAgentKind.allCases.map { (kind: $0, registration: nil) }
            + registry.registrations.compactMap { registration in
                builtInKindIDs.contains(registration.id)
                    ? nil
                    : (kind: .custom(registration.id), registration: registration)
            }
        var hookCandidatesBySession: [SessionKey: Entry] = [:]
        var hookCandidatesByPanel: [PanelKey: Entry] = [:]

        for (kind, registration) in hookKinds {
            let fileURL = kind.hookStoreFileURL(homeDirectory: homeDirectory)
            guard fileManager.fileExists(atPath: fileURL.path),
                  let data = try? Data(contentsOf: fileURL),
                  let state = try? decoder.decode(RestorableAgentHookSessionStoreFile.self, from: data) else {
                continue
            }

            for record in state.sessions.values {
                let normalizedSessionId = record.sessionId.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !normalizedSessionId.isEmpty,
                      let workspaceId = UUID(uuidString: record.workspaceId),
                      let panelId = UUID(uuidString: record.surfaceId),
                      hookRecordIsRestorable(
                          record,
                          kind: kind,
                          fileManager: fileManager,
                          claudeTranscriptLookup: claudeTranscriptLookup
                      ) else {
                    continue
                }

                // Claude `--resume <id>` rejects sessions whose transcript only
                // contains metadata events (e.g. `/rename` immediately after
                // SessionStart, before the user typed anything) with
                // "No conversation found with session ID …". Drop those hook
                // records so cmux doesn't auto-resume them. Same helper is
                // reused by `Workspace.createPanel` for snapshots already
                // embedded in `SessionPanelSnapshot.terminal.agent`.
                if !claudeAgentIsRestorable(
                    kind: kind,
                    sessionId: normalizedSessionId,
                    cwd: record.cwd,
                    environment: record.launchCommand?.environment,
                    fileManager: fileManager
                ) {
                    continue
                }

                let snapshot = SessionRestorableAgentSnapshot(
                    kind: kind,
                    sessionId: normalizedSessionId,
                    workingDirectory: normalizedWorkingDirectory(record.cwd),
                    launchCommand: record.launchCommand,
                    registration: registration
                )
                let key = PanelKey(workspaceId: workspaceId, panelId: panelId)
                let sessionKey = SessionKey(kind: kind, sessionId: normalizedSessionId)
                let liveProcessID = liveScopedProcessID(
                    for: record,
                    kind: kind,
                    workspaceId: workspaceId,
                    panelId: panelId,
                    processArgumentsProvider: processArgumentsProvider
                )
                let entry = Entry(
                    snapshot: snapshot,
                    lifecycle: record.agentLifecycle,
                    updatedAt: record.updatedAt,
                    processIDs: liveProcessID.map { [$0] } ?? []
                )
                if hookCandidatesByPanel[key]?.updatedAt ?? -Double.infinity <= record.updatedAt {
                    hookCandidatesByPanel[key] = entry
                }
                if hookCandidatesBySession[sessionKey]?.updatedAt ?? -Double.infinity <= record.updatedAt {
                    hookCandidatesBySession[sessionKey] = entry
                }
                guard record.pid == nil || liveProcessID != nil else {
                    continue
                }
                if let existing = resolved[key], existing.updatedAt > record.updatedAt {
                    continue
                }
                resolved[key] = entry
            }
        }

        for (key, detected) in detectedSnapshots {
            if let existing = Self.matchingHookEntry(
                for: detected.snapshot,
                resolved: resolved[key],
                panelCandidate: hookCandidatesByPanel[key],
                sessionCandidate: hookCandidatesBySession[
                    SessionKey(kind: detected.snapshot.kind, sessionId: detected.snapshot.sessionId)
                ]
            ) {
                resolved[key] = Entry(
                    snapshot: detected.snapshot,
                    lifecycle: existing.lifecycle,
                    updatedAt: existing.updatedAt,
                    processIDs: detected.processIDs
                )
            } else {
                resolved[key] = Entry(
                    snapshot: detected.snapshot,
                    lifecycle: nil,
                    updatedAt: 0,
                    processIDs: detected.processIDs
                )
            }
        }

        return RestorableAgentSessionIndex(entriesByPanel: resolved)
    }

    private static func matchingHookEntry(
        for snapshot: SessionRestorableAgentSnapshot,
        resolved: Entry?,
        panelCandidate: Entry?,
        sessionCandidate: Entry?
    ) -> Entry? {
        [resolved, panelCandidate, sessionCandidate].compactMap { $0 }
            .filter {
                $0.snapshot.kind == snapshot.kind &&
                    $0.snapshot.sessionId == snapshot.sessionId
            }
            .max { $0.updatedAt < $1.updatedAt }
    }

    private static func normalizedWorkingDirectory(_ rawValue: String?) -> String? {
        normalizedNonEmptyValue(rawValue)
    }

    private static func hookRecordIsRestorable(
        _ record: RestorableAgentHookSessionRecord,
        kind: RestorableAgentKind,
        fileManager: FileManager,
        claudeTranscriptLookup: ClaudeTranscriptLookupCache
    ) -> Bool {
        guard kind == .claude else {
            return record.isRestorable != false
        }
        if let transcriptPath = normalizedNonEmptyValue(record.transcriptPath),
           regularNonEmptyFileExists(
               atPath: (transcriptPath as NSString).expandingTildeInPath,
               fileManager: fileManager
           ) {
            return true
        }
        return claudeTranscriptExists(for: record, fileManager: fileManager, lookup: claudeTranscriptLookup)
    }

    private static func claudeTranscriptExists(
        for record: RestorableAgentHookSessionRecord,
        fileManager: FileManager,
        lookup: ClaudeTranscriptLookupCache
    ) -> Bool {
        guard let sessionId = normalizedNonEmptyValue(record.sessionId),
              claudeSessionIdIsSafeFilename(sessionId) else {
            return false
        }

        let roots = lookup.configRoots(for: record)
        guard !roots.isEmpty else { return false }

        let cwd = normalizedWorkingDirectory(record.cwd)
            ?? normalizedWorkingDirectory(record.launchCommand?.workingDirectory)
        for root in roots {
            if let cwd,
               claudeTranscriptFileExists(
                   configRoot: root,
                   projectDirName: encodeClaudeProjectDir(cwd),
                   sessionId: sessionId,
                   fileManager: fileManager
               ) {
                return true
            }
            if claudeTranscriptFileExistsInAnyProject(
                configRoot: root,
                sessionId: sessionId,
                fileManager: fileManager,
                lookup: lookup
            ) {
                return true
            }
        }
        return false
    }

    private static func claudeSessionIdIsSafeFilename(_ sessionId: String) -> Bool {
        sessionId.range(of: #"[\\/]"#, options: .regularExpression) == nil
            && !sessionId.isEmpty
            && sessionId != "."
            && sessionId != ".."
    }

    static func encodeClaudeProjectDir(_ path: String) -> String {
        path.replacingOccurrences(of: "/", with: "-")
    }

    private static func claudeTranscriptFileExists(
        configRoot: String,
        projectDirName: String,
        sessionId: String,
        fileManager: FileManager
    ) -> Bool {
        let projectsRoot = (configRoot as NSString).appendingPathComponent("projects")
        let projectRoot = (projectsRoot as NSString).appendingPathComponent(projectDirName)
        let path = (projectRoot as NSString).appendingPathComponent("\(sessionId).jsonl")
        return regularNonEmptyFileExists(atPath: path, fileManager: fileManager)
    }

    private static func claudeTranscriptFileExistsInAnyProject(
        configRoot: String,
        sessionId: String,
        fileManager: FileManager,
        lookup: ClaudeTranscriptLookupCache
    ) -> Bool {
        let projectsRoot = (configRoot as NSString).appendingPathComponent("projects")
        for projectDir in lookup.projectDirs(configRoot: configRoot) {
            let projectRoot = (projectsRoot as NSString).appendingPathComponent(projectDir)
            let path = (projectRoot as NSString).appendingPathComponent("\(sessionId).jsonl")
            if regularNonEmptyFileExists(atPath: path, fileManager: fileManager) {
                return true
            }
        }
        return false
    }

    private final class ClaudeTranscriptLookupCache {
        private let homeDirectory: String
        private let fileManager: FileManager
        private var defaultRoots: [String]?
        private var projectDirsByConfigRoot: [String: [String]] = [:]

        init(homeDirectory: String, fileManager: FileManager) {
            self.homeDirectory = homeDirectory
            self.fileManager = fileManager
        }

        func configRoots(for record: RestorableAgentHookSessionRecord) -> [String] {
            if let configured = RestorableAgentSessionIndex.normalizedNonEmptyValue(
                record.launchCommand?.environment?["CLAUDE_CONFIG_DIR"]
            ) {
                return [
                    ClaudeConfigDirectoryPath.preferredPath(
                        configured,
                        fileManager: fileManager,
                        homeDirectory: homeDirectory
                    ),
                ]
            }

            if let defaultRoots {
                return defaultRoots
            }

            var roots: [String] = []
            var seen: Set<String> = []
            func appendRoot(_ path: String) {
                let standardized = (path as NSString).standardizingPath
                guard seen.insert(standardized).inserted else { return }
                roots.append(standardized)
            }

            let accountRoot = (homeDirectory as NSString).appendingPathComponent(".codex-accounts/claude")
            if directoryExists(atPath: accountRoot),
               let accountDirs = try? fileManager.contentsOfDirectory(atPath: accountRoot) {
                for accountDir in accountDirs.sorted() {
                    appendRoot((accountRoot as NSString).appendingPathComponent(accountDir))
                }
            }
            appendRoot((homeDirectory as NSString).appendingPathComponent(".claude"))
            appendRoot(
                ClaudeConfigDirectoryPath.preferredPath(
                    (homeDirectory as NSString).appendingPathComponent(".subrouter/codex/claude"),
                    fileManager: fileManager,
                    homeDirectory: homeDirectory
                )
            )

            defaultRoots = roots
            return roots
        }

        func projectDirs(configRoot: String) -> [String] {
            let standardizedRoot = (configRoot as NSString).standardizingPath
            if let cached = projectDirsByConfigRoot[standardizedRoot] {
                return cached
            }

            let projectsRoot = (standardizedRoot as NSString).appendingPathComponent("projects")
            guard directoryExists(atPath: projectsRoot),
                  let projectDirs = try? fileManager.contentsOfDirectory(atPath: projectsRoot) else {
                projectDirsByConfigRoot[standardizedRoot] = []
                return []
            }

            projectDirsByConfigRoot[standardizedRoot] = projectDirs
            return projectDirs
        }

        private func directoryExists(atPath path: String) -> Bool {
            var isDirectory: ObjCBool = false
            return fileManager.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
        }
    }

    private static func regularNonEmptyFileExists(atPath path: String, fileManager: FileManager) -> Bool {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory),
              !isDirectory.boolValue,
              let attrs = try? fileManager.attributesOfItem(atPath: path),
              let size = attrs[.size] as? NSNumber else {
            return false
        }
        return size.intValue > 0
    }

    private static func liveScopedProcessID(
        for record: RestorableAgentHookSessionRecord,
        kind: RestorableAgentKind,
        workspaceId: UUID,
        panelId: UUID,
        processArgumentsProvider: (Int) -> CmuxTopProcessArguments?
    ) -> Int? {
        guard let pid = record.pid else {
            return nil
        }
        guard pid > 0,
              let process = processArgumentsProvider(pid),
              process.matchesCMUXScope(workspaceId: workspaceId, surfaceId: panelId) else {
            return nil
        }

        if let liveKind = normalizedProcessValue(process.environment["CMUX_AGENT_LAUNCH_KIND"]),
           liveKind.compare(kind.rawValue, options: [.caseInsensitive, .literal]) != .orderedSame {
            return nil
        }

        guard let recordedExecutable = recordedExecutableBasename(record),
              let liveExecutable = process.arguments.first.map(executableBasename) else {
            return pid
        }
        guard liveExecutable.compare(recordedExecutable, options: [.caseInsensitive, .literal]) == .orderedSame else {
            return nil
        }
        return pid
    }

    private static func recordedExecutableBasename(_ record: RestorableAgentHookSessionRecord) -> String? {
        let executable = normalizedProcessValue(record.launchCommand?.executablePath)
            ?? normalizedProcessValue(record.launchCommand?.arguments.first)
        return executable.map(executableBasename)
    }

    private static func executableBasename(_ value: String) -> String {
        (value as NSString).lastPathComponent
    }

    private static func normalizedProcessValue(_ value: String?) -> String? {
        normalizedNonEmptyValue(value)
    }

    private static func normalizedNonEmptyValue(_ value: String?) -> String? {
        guard let rawValue = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawValue.isEmpty else {
            return nil
        }
        return rawValue
    }

    /// Resolve the directory under which Claude stores its session
    /// transcripts (defaults to `~/.claude`). If the launch environment
    /// pinned a `CLAUDE_CONFIG_DIR`, use that — running it through the
    /// subrouter→codex-accounts redirect that the Claude wrapper applies.
    /// Exposed for callers that need to look up transcripts at restoration
    /// time without re-importing `CMUXAgentLaunch`.
    static func claudeConfigDir(in environment: [String: String]?) -> String {
        if let raw = environment?["CLAUDE_CONFIG_DIR"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty {
            return ClaudeConfigDirectoryPath.preferredPath(raw)
        }
        return (NSString(string: "~/.claude").expandingTildeInPath as String)
    }

    /// Returns true if Claude's session transcript at
    /// `<claudeConfigDir>/projects/<encoded-cwd>/<sessionId>.jsonl` contains at
    /// least one `user` or `assistant` event. Returns true (do not skip) when
    /// the transcript is unreadable or absent — letting Claude itself produce
    /// the canonical error if it's truly broken at resume time.
    static func claudeTranscriptHasConversation(
        cwd: String,
        sessionId: String,
        claudeConfigDir: String,
        fileManager: FileManager = .default
    ) -> Bool {
        let trimmedCwd = cwd.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedCwd.isEmpty else { return true }
        // Claude encodes a project dir as `cwd.replacingOccurrences("/", with: "-")`
        // on the raw cwd Claude saw at startup — no symlink resolution. The leading
        // `/` in an absolute path becomes the leading `-`, so an absolute cwd
        // `/private/tmp/aaa` maps to `-private-tmp-aaa`. Do NOT standardize the
        // path: macOS's `NSString.standardizingPath` collapses `/private/tmp` →
        // `/tmp`, which would point at the wrong project directory.
        let encodedProject = trimmedCwd.replacingOccurrences(of: "/", with: "-")
        let projectsRoot = (claudeConfigDir as NSString).appendingPathComponent("projects")
        let projectDir = (projectsRoot as NSString).appendingPathComponent(encodedProject)
        let transcript = (projectDir as NSString)
            .appendingPathComponent("\(sessionId).jsonl")

        guard fileManager.fileExists(atPath: transcript) else {
            // Unknown — let Claude error if needed; do not pre-emptively drop.
            return true
        }
        guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: transcript)) else {
            return true
        }
        defer { try? handle.close() }
        // Scan the file in chunks; the "user" / "assistant" `type` field
        // appears near the start of each line in Claude's JSONL.
        var leftover = Data()
        let chunkSize = 64 * 1024
        var totalRead = 0
        let maxScan = 1 * 1024 * 1024 // 1 MB cap; transcripts with content cross this trivially.
        while totalRead < maxScan {
            let chunk: Data
            do {
                chunk = try handle.read(upToCount: chunkSize) ?? Data()
            } catch {
                return true
            }
            if chunk.isEmpty { break }
            totalRead += chunk.count
            leftover.append(chunk)
            while let newlineIndex = leftover.firstIndex(of: 0x0A) {
                let line = leftover.subdata(in: leftover.startIndex..<newlineIndex)
                leftover.removeSubrange(leftover.startIndex...newlineIndex)
                if lineDeclaresConversationEvent(line) {
                    return true
                }
            }
        }
        if !leftover.isEmpty, lineDeclaresConversationEvent(leftover) {
            return true
        }
        return false
    }

    /// Single eligibility check shared by the load loop and `Workspace.createPanel`
    /// for whether a candidate Claude/agent session can be auto-resumed.
    /// Non-Claude agents pass through (they don't share Claude's metadata-only
    /// failure mode). Empty/missing cwd fails open — let Claude itself produce
    /// the canonical error if it's truly broken at resume time. Centralising
    /// here keeps both surfaces in sync if Claude's transcript rules change.
    static func claudeAgentIsRestorable(
        kind: RestorableAgentKind,
        sessionId: String,
        cwd: String?,
        environment: [String: String]?,
        fileManager: FileManager = .default
    ) -> Bool {
        guard kind == .claude else { return true }
        guard let cwd, !cwd.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return true
        }
        return claudeTranscriptHasConversation(
            cwd: cwd,
            sessionId: sessionId,
            claudeConfigDir: claudeConfigDir(in: environment),
            fileManager: fileManager
        )
    }

    /// Cached regex for `lineDeclaresConversationEvent`. Compiled once so the
    /// per-line scan stays cheap. Tolerates any whitespace around the colon
    /// (valid JSON), which a fixed-substring check would miss for inputs like
    /// `"type" : "assistant"`.
    private static let conversationEventRegex: NSRegularExpression = {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(
            pattern: #""type"\s*:\s*"(?:user|assistant)""#,
            options: []
        )
    }()

    private static func lineDeclaresConversationEvent(_ line: Data) -> Bool {
        // A line carrying a top-level `"type": "user"` or `"type": "assistant"`
        // is a real conversation event. Metadata-only lines (`custom-title`,
        // `agent-name`, `permission-mode`, etc.) don't match. We avoid full
        // JSON parsing per line for hot-path performance — the regex still
        // costs <1 µs per line with a precompiled NSRegularExpression.
        guard !line.isEmpty,
              let text = String(data: line, encoding: .utf8) else {
            return false
        }
        let nsLength = (text as NSString).length
        return conversationEventRegex.firstMatch(
            in: text,
            options: [],
            range: NSRange(location: 0, length: nsLength)
        ) != nil
    }

    private init(entriesByPanel: [PanelKey: Entry]) {
        self.entriesByPanel = entriesByPanel
        var entriesByPanelId: [UUID: Entry] = [:]
        for (key, entry) in entriesByPanel {
            let existing = entriesByPanelId[key.panelId]
            if existing == nil || entry.updatedAt >= (existing?.updatedAt ?? 0) {
                entriesByPanelId[key.panelId] = entry
            }
        }
        self.entriesByPanelId = entriesByPanelId
    }
}

nonisolated struct SurfaceResumeBindingIndex: Sendable {
    static let empty = SurfaceResumeBindingIndex(bindingsByPanel: [:])

    typealias PanelKey = RestorableAgentSessionIndex.PanelKey

    private let bindingsByPanel: [PanelKey: SurfaceResumeBindingSnapshot]
    private let bindingsByPanelId: [UUID: SurfaceResumeBindingSnapshot]

    init(bindingsByPanel: [PanelKey: SurfaceResumeBindingSnapshot]) {
        self.bindingsByPanel = bindingsByPanel
        var bindingsByPanelId: [UUID: SurfaceResumeBindingSnapshot] = [:]
        for (key, binding) in bindingsByPanel {
            let existing = bindingsByPanelId[key.panelId]
            if existing == nil || binding.updatedAt >= (existing?.updatedAt ?? 0) {
                bindingsByPanelId[key.panelId] = binding
            }
        }
        self.bindingsByPanelId = bindingsByPanelId
    }

    func binding(workspaceId: UUID, panelId: UUID) -> SurfaceResumeBindingSnapshot? {
        bindingsByPanel[PanelKey(workspaceId: workspaceId, panelId: panelId)] ?? bindingsByPanelId[panelId]
    }

    static func loadProcessDetectedBindingsSynchronously(
        fileManager: FileManager = .default
    ) -> SurfaceResumeBindingIndex {
        let detectedBindings = processDetectedTmuxBindings(fileManager: fileManager)
        return SurfaceResumeBindingIndex(bindingsByPanel: detectedBindings.mapValues(\.binding))
    }

    static func loadIncludingProcessDetectedBindings(
        fileManager: FileManager = .default
    ) async -> SurfaceResumeBindingIndex {
        await Task.detached(priority: .utility) {
            loadProcessDetectedBindingsSynchronously(fileManager: fileManager)
        }.value
    }
}

struct ProcessDetectedResumeIndexes: Sendable {
    let restorableAgentIndex: RestorableAgentSessionIndex
    let surfaceResumeBindingIndex: SurfaceResumeBindingIndex

    static func load(
        homeDirectory: String = NSHomeDirectory(),
        fileManager: FileManager = .default
    ) async -> ProcessDetectedResumeIndexes {
        await Task.detached(priority: .utility) {
            loadSynchronously(homeDirectory: homeDirectory, fileManager: fileManager)
        }.value
    }

    static func loadSynchronously(
        homeDirectory: String = NSHomeDirectory(),
        fileManager: FileManager = .default
    ) -> ProcessDetectedResumeIndexes {
        let capturedAt = Date().timeIntervalSince1970
        let processSnapshot = CmuxTopProcessSnapshot.capture(includeProcessDetails: true)
        let registry = CmuxVaultAgentRegistry.load(homeDirectory: homeDirectory, fileManager: fileManager)
        let detectedSnapshots = RestorableAgentSessionIndex.processDetectedSnapshots(
            registry: registry,
            fileManager: fileManager,
            processSnapshot: processSnapshot,
            capturedAt: capturedAt
        )
        let restorableAgentIndex = RestorableAgentSessionIndex.load(
            homeDirectory: homeDirectory,
            fileManager: fileManager,
            registry: registry,
            detectedSnapshots: detectedSnapshots
        )
        let detectedBindings = SurfaceResumeBindingIndex.processDetectedTmuxBindings(
            fileManager: fileManager,
            processSnapshot: processSnapshot,
            capturedAt: capturedAt
        )
        return ProcessDetectedResumeIndexes(
            restorableAgentIndex: restorableAgentIndex,
            surfaceResumeBindingIndex: SurfaceResumeBindingIndex(bindingsByPanel: detectedBindings.mapValues(\.binding))
        )
    }
}

private extension CmuxTopProcessArguments {
    func environmentUUID(forKey key: String) -> UUID? {
        guard let rawValue = environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawValue.isEmpty else {
            return nil
        }
        return UUID(uuidString: rawValue)
    }
}
