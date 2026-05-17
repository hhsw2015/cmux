import Foundation

/// Coordinates a tsm worktree switch + per-branch layout swap.
///
/// The switcher itself does no UI work; it returns a plan describing
/// what cmux should do (detach which sessions, attach which, materialize
/// which layout). The host translates the plan into bonsplit operations
/// + panel attaches. Keeps the heavy bonsplit knowledge in the host so
/// the package stays GUI-free.
public struct BranchWorkspaceSwitcher: Sendable {
    public let backend: any DeepSessionDaemonBackend
    public let manifestStore: ProjectManifestStore

    public init(backend: any DeepSessionDaemonBackend, manifestStore: ProjectManifestStore) {
        self.backend = backend
        self.manifestStore = manifestStore
    }

    public struct SwitchPlan: Sendable, Equatable {
        public let project: String
        public let fromBranch: String
        public let toBranch: String
        public let detachSessions: [String]
        public let layoutToMaterialize: PanelLayoutTree?
        /// Sessions referenced by the new layout that don't exist yet on
        /// the daemon. Host will create them via backend.createSession.
        public let sessionsToCreate: [PanelDescriptor]
    }

    public enum SwitchError: Error, Equatable {
        case projectNotFound
        case targetBranchUnknown
        case daemonError(String)
    }

    /// Build a switch plan without mutating anything. Host applies the
    /// plan via `apply(_:)` once the user confirms.
    public func plan(
        project: String,
        from currentBranch: String,
        to targetBranch: String,
        currentLayout: PanelLayoutTree?,
        liveSessionNames: Set<String>
    ) throws -> SwitchPlan {
        var manifest: ProjectManifest
        do {
            manifest = try manifestStore.load(name: project)
        } catch {
            throw SwitchError.projectNotFound
        }

        let layout = manifest.layouts[targetBranch]
            ?? cloneCurrentLayoutForBranch(
                currentLayout: currentLayout,
                fromBranch: currentBranch,
                toBranch: targetBranch
            )

        // Persist the cloned layout so future visits to this branch reuse
        // the same layout instead of re-cloning every time.
        if manifest.layouts[targetBranch] == nil, let layout {
            manifest.layouts[targetBranch] = layout
            try? manifestStore.save(manifest)
        }

        let referenced = layout?.leaves.map(\.sessionName) ?? []
        let referencedSet = Set(referenced)
        let detach: [String] = (currentLayout?.leaves.map(\.sessionName) ?? [])
            .filter { !referencedSet.contains($0) }

        let toCreate = layout?.leaves.filter { !liveSessionNames.contains($0.sessionName) } ?? []

        return SwitchPlan(
            project: project,
            fromBranch: currentBranch,
            toBranch: targetBranch,
            detachSessions: detach,
            layoutToMaterialize: layout,
            sessionsToCreate: toCreate
        )
    }

    /// Apply the plan: detach old sessions, create missing ones, run the
    /// daemon-side worktree switch. Host re-renders the layout afterward.
    public func apply(_ plan: SwitchPlan) async throws {
        for name in plan.detachSessions {
            try? await backend.detachSession(name)
        }
        for descriptor in plan.sessionsToCreate {
            try await backend.createSession(
                name: descriptor.sessionName,
                cmd: descriptor.cmd,
                dir: descriptor.dir
            )
        }
        do {
            try await backend.switchWorktree(branch: plan.toBranch)
        } catch {
            throw SwitchError.daemonError(String(describing: error))
        }
    }

    /// Default: clone the current layout into the target branch. Mirrors
    /// the panel structure but rewrites session names so each branch has
    /// its own isolated set of sessions.
    private func cloneCurrentLayoutForBranch(
        currentLayout: PanelLayoutTree?,
        fromBranch: String,
        toBranch: String
    ) -> PanelLayoutTree? {
        guard let currentLayout else { return nil }
        return cloneTree(currentLayout, from: fromBranch, to: toBranch)
    }

    private func cloneTree(
        _ tree: PanelLayoutTree,
        from: String,
        to: String
    ) -> PanelLayoutTree {
        switch tree {
        case .panel(let descriptor):
            let renamed = PanelDescriptor(
                sessionName: rename(descriptor.sessionName, from: from, to: to),
                cmd: descriptor.cmd,
                dir: descriptor.dir,
                capturedCwd: descriptor.capturedCwd,
                capturedEnv: descriptor.capturedEnv,
                keepAlive: descriptor.keepAlive
            )
            return .panel(renamed)
        case .split(let direction, let ratio, let children):
            return .split(
                direction: direction,
                ratio: ratio,
                children: children.map { cloneTree($0, from: from, to: to) }
            )
        }
    }

    private func rename(_ name: String, from: String, to: String) -> String {
        // Convention: session names live under "<branch>/<purpose>" so a
        // branch switch only swaps the prefix. Names without a prefix
        // (e.g., "editor") get one prepended.
        if name.hasPrefix("\(from)/") {
            return "\(to)/" + name.dropFirst(from.count + 1)
        }
        if !name.contains("/") {
            return "\(to)/\(name)"
        }
        // Some other prefix; replace it with the new branch.
        let parts = name.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        if parts.count == 2 {
            return "\(to)/\(parts[1])"
        }
        return "\(to)/\(name)"
    }
}
