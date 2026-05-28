import Foundation

/// `cmux worktree create --issue 1234` and friends.
///
/// Phase 4 of the fork enhancement plan. Creates a git worktree whose branch
/// name and metadata are derived from a GitHub issue, so the agent (and the
/// human) lands in a folder whose name immediately tells them what the work
/// is about.
///
/// Borrowed conventions from `aschreifels/cwt`:
///
///   - Branch name = `issue-<num>-<kebab-title>` (truncated at 40 chars).
///   - Worktree directory mirrors the branch name so `cd` autocomplete
///     remains useful.
///   - A small `.cmux-worktree-meta.json` sidecar inside the worktree records
///     the issue number, title, URL, and source repo so future tooling
///     (workspace title, PR description templating) can read it without
///     re-shelling out to `gh`.
///
/// Only the subset that doesn't require socket access lives here; opening the
/// resulting worktree as a cmux workspace can be done manually with
/// `cmux open <path>` or by an editor integration. Keeping this command
/// daemon-free means it works even when no cmux app is running, which is the
/// common case when scripts call `cmux worktree create` from CI.
func runWorktreeSubcommand(commandArgs: [String]) throws {
    guard let action = commandArgs.first else {
        throw CLIError(message: """
        usage:
          cmux worktree create --issue <num>     [--repo owner/name] [--base main] [--path <dir>]
          cmux worktree create --pr <num>        [--repo owner/name] [--base main] [--path <dir>]
          cmux worktree create --branch <name>   [--base main] [--path <dir>]
        """)
    }
    let rest = Array(commandArgs.dropFirst())
    switch action {
    case "create":
        try worktreeCreate(rest)
    default:
        throw CLIError(message: "unknown worktree subcommand '\(action)'")
    }
}

// MARK: - private

private struct WorktreeCreateOptions {
    var issue: Int?
    var pr: Int?
    var branch: String?
    var repo: String?
    var base: String = "main"
    var path: String?
}

private func worktreeCreate(_ args: [String]) throws {
    var opts = WorktreeCreateOptions()
    var i = 0
    while i < args.count {
        let a = args[i]
        let next: () throws -> String = {
            guard i + 1 < args.count else {
                throw CLIError(message: "\(a) requires a value")
            }
            i += 1
            return args[i]
        }
        switch a {
        case "--issue":
            let raw = try next()
            guard let n = Int(raw) else { throw CLIError(message: "--issue expects an integer, got '\(raw)'") }
            opts.issue = n
        case "--pr":
            let raw = try next()
            guard let n = Int(raw) else { throw CLIError(message: "--pr expects an integer, got '\(raw)'") }
            opts.pr = n
        case "--branch":
            opts.branch = try next()
        case "--repo":
            opts.repo = try next()
        case "--base":
            opts.base = try next()
        case "--path":
            opts.path = try next()
        default:
            throw CLIError(message: "unknown flag '\(a)' for worktree create")
        }
        i += 1
    }

    let chosen = [opts.issue != nil, opts.pr != nil, opts.branch != nil].filter { $0 }.count
    guard chosen == 1 else {
        throw CLIError(message: "specify exactly one of --issue, --pr, --branch")
    }

    let repoRoot = try findGitRepoRoot()

    let derived = try deriveBranchAndMeta(opts: opts, repoRoot: repoRoot)
    let worktreePath = opts.path ?? defaultWorktreePath(repoRoot: repoRoot, branch: derived.branch)

    if FileManager.default.fileExists(atPath: worktreePath) {
        throw CLIError(message: "path already exists: \(worktreePath)")
    }

    try ensureBaseRefAvailable(repoRoot: repoRoot, base: opts.base)

    try runGit(repoRoot: repoRoot, [
        "worktree", "add", "-b", derived.branch, worktreePath, opts.base
    ])

    if let meta = derived.meta {
        try writeMeta(worktreePath: worktreePath, meta: meta)
    }

    print(worktreePath)
}

private struct WorktreeMeta: Codable {
    var issue: Int?
    var pr: Int?
    var title: String?
    var url: String?
    var repo: String?
    var createdAt: String
}

private struct DerivedBranchAndMeta {
    let branch: String
    let meta: WorktreeMeta?
}

private func deriveBranchAndMeta(opts: WorktreeCreateOptions, repoRoot: String) throws -> DerivedBranchAndMeta {
    if let branch = opts.branch {
        return DerivedBranchAndMeta(branch: branch, meta: nil)
    }
    if let issue = opts.issue {
        let info = try fetchGhIssue(number: issue, repo: opts.repo, kind: "issue")
        let branch = formatBranch(prefix: "issue-\(issue)", title: info.title)
        return DerivedBranchAndMeta(
            branch: branch,
            meta: WorktreeMeta(
                issue: issue,
                pr: nil,
                title: info.title,
                url: info.url,
                repo: opts.repo,
                createdAt: ISO8601DateFormatter().string(from: Date())
            )
        )
    }
    if let pr = opts.pr {
        let info = try fetchGhIssue(number: pr, repo: opts.repo, kind: "pr")
        let branch = formatBranch(prefix: "pr-\(pr)", title: info.title)
        return DerivedBranchAndMeta(
            branch: branch,
            meta: WorktreeMeta(
                issue: nil,
                pr: pr,
                title: info.title,
                url: info.url,
                repo: opts.repo,
                createdAt: ISO8601DateFormatter().string(from: Date())
            )
        )
    }
    fatalError("checked above")
}

private struct GhIssueInfo {
    var title: String
    var url: String
}

private func fetchGhIssue(number: Int, repo: String?, kind: String) throws -> GhIssueInfo {
    var args = [kind, "view", String(number), "--json", "title,url"]
    if let repo {
        args.append(contentsOf: ["--repo", repo])
    }
    let result = try runProcess(executable: "gh", args: args)
    guard result.exitCode == 0 else {
        throw CLIError(message: "gh \(kind) view #\(number) failed: \(result.stderr)")
    }
    struct Payload: Decodable { var title: String; var url: String }
    guard let data = result.stdout.data(using: .utf8),
          let parsed = try? JSONDecoder().decode(Payload.self, from: data) else {
        throw CLIError(message: "gh returned unparseable json: \(result.stdout)")
    }
    return GhIssueInfo(title: parsed.title, url: parsed.url)
}

private func formatBranch(prefix: String, title: String) -> String {
    let kebab = title
        .lowercased()
        .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
        .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    let truncated = String(kebab.prefix(40))
    if truncated.isEmpty { return prefix }
    return "\(prefix)-\(truncated)"
}

private func defaultWorktreePath(repoRoot: String, branch: String) -> String {
    let parent = (repoRoot as NSString).deletingLastPathComponent
    let repoName = (repoRoot as NSString).lastPathComponent
    return "\(parent)/\(repoName)-worktrees/\(branch)"
}

private func writeMeta(worktreePath: String, meta: WorktreeMeta) throws {
    let url = URL(fileURLWithPath: worktreePath).appendingPathComponent(".cmux-worktree-meta.json")
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(meta)
    try data.write(to: url)
}

private func findGitRepoRoot() throws -> String {
    let result = try runProcess(executable: "git", args: ["rev-parse", "--show-toplevel"])
    guard result.exitCode == 0 else {
        throw CLIError(message: "not inside a git repository: \(result.stderr)")
    }
    return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
}

private func ensureBaseRefAvailable(repoRoot: String, base: String) throws {
    let result = try runProcess(executable: "git", args: ["-C", repoRoot, "rev-parse", "--verify", "\(base)^{commit}"])
    if result.exitCode != 0 {
        // Attempt to fetch the base from origin so a freshly-cloned repo
        // doesn't fail when origin/main is the only authoritative ref.
        let fetch = try runProcess(executable: "git", args: ["-C", repoRoot, "fetch", "origin", base])
        if fetch.exitCode != 0 {
            throw CLIError(message: "base ref '\(base)' not found and fetch failed: \(fetch.stderr)")
        }
    }
}

private func runGit(repoRoot: String, _ args: [String]) throws {
    var full = ["-C", repoRoot]
    full.append(contentsOf: args)
    let result = try runProcess(executable: "git", args: full)
    guard result.exitCode == 0 else {
        throw CLIError(message: "git \(args.joined(separator: " ")) failed: \(result.stderr)")
    }
}

private struct ProcessResult {
    var exitCode: Int32
    var stdout: String
    var stderr: String
}

private func runProcess(executable: String, args: [String]) throws -> ProcessResult {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = [executable] + args
    let outPipe = Pipe()
    let errPipe = Pipe()
    process.standardOutput = outPipe
    process.standardError = errPipe
    try process.run()
    process.waitUntilExit()
    let outData = (try? outPipe.fileHandleForReading.readToEnd()) ?? Data()
    let errData = (try? errPipe.fileHandleForReading.readToEnd()) ?? Data()
    return ProcessResult(
        exitCode: process.terminationStatus,
        stdout: String(data: outData, encoding: .utf8) ?? "",
        stderr: String(data: errData, encoding: .utf8) ?? ""
    )
}
