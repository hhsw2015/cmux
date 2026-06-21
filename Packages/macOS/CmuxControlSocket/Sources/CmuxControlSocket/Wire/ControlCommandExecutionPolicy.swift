/// Where a v2 control command executes (was `SocketCommandExecutionPolicy` +
/// the `socketWorkerV2Methods`/`mainThreadCallableSocketWorkerV2Methods`
/// tables on `TerminalController`).
///
/// An isolation-intent value: the dispatcher consults it to decide whether a
/// method runs on the main actor or stays on the socket-worker thread. The
/// main-thread-callable refinement only exists for worker-lane methods, so it
/// is an associated value of that case rather than a separate table.
public enum ControlCommandExecutionPolicy: Sendable, Equatable {
    /// The command must run on the main actor (UI/window/workspace state).
    case mainActor
    /// The command runs on the socket-worker thread (blocking or long-running
    /// work that must not occupy the main actor). `mainThreadCallable` marks
    /// the pure, non-blocking probes that may also be invoked synchronously
    /// from the main thread.
    case socketWorker(mainThreadCallable: Bool)

    /// Classifies a method: every `vm.`- and `remotes.`-prefixed method and the
    /// fixed socket-worker set run on the worker; everything else runs on the
    /// main actor.
    ///
    /// `remotes.*` (the `cmux remotes` device-registry verbs) make blocking,
    /// authenticated web API calls just like `vm.*`, so they must stay off the
    /// main actor; a prefix match keeps the three verbs in lockstep without
    /// listing each.
    ///
    /// - Parameter method: The trimmed method name.
    public init(forMethod method: String) {
        if method.hasPrefix("vm.") || method.hasPrefix("remotes.")
            || Self.socketWorkerMethods.contains(method) {
            self = .socketWorker(
                mainThreadCallable: Self.mainThreadCallableSocketWorkerMethods.contains(method)
            )
        } else {
            self = .mainActor
        }
    }

    /// True when the command runs on the socket-worker thread.
    public var runsOnSocketWorker: Bool {
        if case .socketWorker = self { return true }
        return false
    }

    /// Methods that run on the socket-worker thread instead of the main actor.
    private static let socketWorkerMethods: Set<String> = [
        "system.ping",
        "system.capabilities",
        "auth.status",
        "auth.sign_in_url",
        "auth.begin_sign_in",
        "auth.sign_out",
        "feedback.submit",
        "feed.push",
        "feed.permission.reply",
        "feed.question.reply",
        "feed.exit_plan.reply",
        "browser.download.wait",
        "browser.profiles.list",
        "browser.profiles.create",
        "browser.profiles.rename",
        "browser.profiles.clear",
        "browser.profiles.delete",
        "browser.import.cookies",
        "mobile.attach_ticket.create",
        "system.top",
        "system.memory",
        // `workspace.env` is a read that resolves a workspace and copies its
        // env dictionary behind a `v2MainSync` hop, so it runs on the worker
        // lane like the other workspace reads below.
        "workspace.env",
        "workspace.remote.pty_sessions",
        "workspace.remote.pty_close",
        "workspace.remote.pty_detach",
        "workspace.remote.pty_bridge",
        "workspace.remote.pty_resize",
        "remote.tmux.sessions",
        "remote.tmux.attach",
        "remote.tmux.detach",
        "remote.tmux.state",
        "remote.tmux.mirror",
        "remote.tmux.window",
        "sidebar.custom.validate",
        "sidebar.custom.reload",
        "sidebar.custom.select",
        "sidebar.custom.open",
        // debug.sidebar.simulate_drag intentionally runs on the socket worker
        // so its Thread.sleep between drag-state ticks doesn't block the main
        // actor (which still owns the SidebarDragState mutations via
        // v2MainSync). Running on .mainActor would deadlock the UI for the
        // entire simulation, defeating the profiling workload.
        "debug.sidebar.simulate_drag",
        // surface.wait_* and notification.wait block for up to ~30 minutes
        // (agent-bus dispatcher waits, TUI test settles). They mutate no UI
        // state — they only loop, snapshot via v2MainSync, and Thread.sleep.
        // Running on .mainActor would freeze the entire UI and queue every
        // other RPC behind them — observed during agent-bus rollout. Worker
        // lane is correct because the actual scan steps inside still hop to
        // main via v2MainSync, but the long sleep loop runs off-main.
        "surface.wait_for_screen_change",
        "surface.wait_for_idle",
        "surface.wait_for_text",
        "surface.wait_for_kind",
        "surface.wait_for_cursor",
        "surface.expect",
        "notification.wait",
    ]

    /// Socket-worker methods that are also safe to invoke from the main
    /// thread (pure, non-blocking probes).
    private static let mainThreadCallableSocketWorkerMethods: Set<String> = [
        "system.ping",
        "system.capabilities",
    ]
}
