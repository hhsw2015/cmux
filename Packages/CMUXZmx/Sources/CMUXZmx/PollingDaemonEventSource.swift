import Foundation

/// Diff-based polling event source for daemons (zmx, tsm) that don't expose
/// a native subscribe API. Phase 5's only implementation; FSEvents-based
/// `TsmSessionDirectoryEventSource` will land in a follow-up PR alongside
/// Phase 6 once we have a real test target running tsm in CI.
///
/// The source polls `backend.listSessions()` every `interval` seconds and
/// emits `DaemonEvent.sessionCreated` / `.sessionExited` whenever the live
/// set diffs.
public actor PollingDaemonEventSource {
    private let backend: SessionDaemonBackend
    private let interval: TimeInterval
    private var task: Task<Void, Never>?
    private var continuation: AsyncStream<DaemonEvent>.Continuation?

    public init(backend: SessionDaemonBackend, interval: TimeInterval = 3.0) {
        self.backend = backend
        self.interval = interval
    }

    public func events() -> AsyncStream<DaemonEvent> {
        AsyncStream { continuation in
            self.attach(continuation: continuation)
        }
    }

    private func attach(continuation: AsyncStream<DaemonEvent>.Continuation) {
        self.continuation = continuation
        continuation.onTermination = { @Sendable _ in
            Task { await self.stop() }
        }
        startLoop()
    }

    private func startLoop() {
        task?.cancel()
        let backend = self.backend
        let interval = self.interval
        let nanos = UInt64(interval * 1_000_000_000)
        task = Task { [weak self] in
            var previous: Set<String> = []
            while !Task.isCancelled {
                let current: Set<String>
                do {
                    let sessions = try await backend.listSessions()
                    current = Set(sessions.map(\.name))
                } catch {
                    // Subprocess failure — don't poison `previous`. Sleep
                    // and retry; cmux's reconcile path treats nil as
                    // "unknown" and won't flip bindings.
                    try? await Task.sleep(nanoseconds: nanos)
                    continue
                }
                let added = current.subtracting(previous)
                let removed = previous.subtracting(current)
                for name in added.sorted() {
                    await self?.emit(.sessionCreated(name: name, cmd: "", dir: ""))
                }
                for name in removed.sorted() {
                    // Polling can't distinguish exited (process died) from
                    // killed (user ran kill); both report as `sessionExited`
                    // with code -1 ("unknown"). Callers interested in the
                    // distinction should subscribe to FSEvents (future).
                    await self?.emit(.sessionExited(name: name, exitCode: -1))
                }
                previous = current
                try? await Task.sleep(nanoseconds: nanos)
            }
        }
    }

    public func stop() {
        task?.cancel()
        task = nil
        continuation?.finish()
        continuation = nil
    }

    private func emit(_ event: DaemonEvent) {
        continuation?.yield(event)
    }
}
