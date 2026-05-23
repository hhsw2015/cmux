import Foundation
import GhosttyKit
import os

/// Pumps bytes between a `HerdrDisplayClient` (which talks to a herdr
/// pane via the cmux fork's RawPty mode) and a `ghostty_surface_t`
/// owned by a cmux terminal panel.
///
/// Wiring:
/// ```
/// herdr daemon  ─stdio─►  raw-pty-attach subprocess  ─AsyncStream─►
///   HerdrDisplayClient  ─Data chunks─►  HerdrSurfaceController
///   ─ghostty_surface_process_output─►  Ghostty rendering
///
/// Ghostty key/text input  ─►  HerdrSurfaceController
///   ─HerdrDisplayClient.send─►  raw-pty-attach subprocess stdin
///   ─stdio─►  herdr daemon
/// ```
///
/// Threading:
/// - The class itself is @MainActor.
/// - The surface pointer is held in a `nonisolated` lock so the panel
///   pump task can run off the main actor and call into Ghostty
///   without hopping back per chunk. Workspace-restore replays a per-
///   pane history snapshot (up to 10MB) into a freshly-mounted
///   surface; running the parse synchronously on the main thread froze
///   the cmux UI for the duration of the replay (see commit message
///   for the panel-pump-off-main fix).
/// - `processOutput` is `nonisolated` and protected by the surface
///   lock so the pump can call it from any thread. The lock is also
///   acquired in `detach` before nil-ing the surface so an in-flight
///   `process_output` call always completes before the pointer is
///   surrendered to Ghostty's free path.
@MainActor
final class HerdrSurfaceController {
    let displayClient: HerdrDisplayClient
    private var pumpTask: Task<Void, Never>?

    /// Nonisolated guarded surface pointer + a generation counter so
    /// `detach` can assert the surface it cleared was the same one
    /// the pump was working against.
    nonisolated private let surfaceState = OSAllocatedUnfairLock<ghostty_surface_t?>(
        initialState: nil
    )

    /// MainActor mirror for callers that need the surface synchronously
    /// (e.g. AppKit hit-testing). Updated under the same lock so reads
    /// from main are consistent with what the pump sees.
    var surface: ghostty_surface_t? {
        surfaceState.withLock { $0 }
    }

    init(displayClient: HerdrDisplayClient) {
        self.displayClient = displayClient
    }

    /// Bind this controller to a Ghostty surface and start pumping.
    /// Idempotent: if an earlier pump is still running, it is cancelled
    /// and a new one is started against the new surface so the
    /// AsyncStream is never consumed by two iterators concurrently.
    /// Caller is responsible for surface lifetime; this controller does
    /// not free the surface on stop.
    func attach(surface: ghostty_surface_t) {
        if pumpTask != nil {
            pumpTask?.cancel()
            pumpTask = nil
        }
        surfaceState.withLock { $0 = surface }
        startPump()
    }

    /// Bind a surface without starting the AsyncStream pump. Used when
    /// some other code (e.g. the debug window) owns the only stream
    /// consumer and feeds bytes into the surface manually. Input
    /// forwarding (sendInput) still works.
    func bindSurfaceWithoutPump(_ surface: ghostty_surface_t) {
        if pumpTask != nil {
            pumpTask?.cancel()
            pumpTask = nil
        }
        surfaceState.withLock { $0 = surface }
    }

    /// Forward a keystroke / pasted text from the Ghostty side back to
    /// the herdr pane. cmux's existing key-event plumbing should call
    /// this when the surface is owned by a HerdrSurfaceController
    /// instead of feeding the local PTY.
    func sendInput(_ data: Data) {
        displayClient.send(data)
    }

    /// Push a chunk of PTY bytes into the bound surface. Returns
    /// `false` if no surface is bound (caller should treat this as
    /// "panel torn down, stop pumping"). Locks `surfaceState` for the
    /// duration of the `ghostty_surface_process_output` call so a
    /// concurrent `detach` waits for the call to finish before nil-ing
    /// the surface — that's what keeps the pump from racing
    /// `ghostty_surface_free` and dereferencing a freed pointer.
    nonisolated func processOutput(_ data: Data) -> Bool {
        return surfaceState.withLock { surface in
            guard let surface else { return false }
            data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                guard let base = raw.baseAddress else { return }
                let cChars = base.assumingMemoryBound(to: CChar.self)
                ghostty_surface_process_output(
                    surface,
                    cChars,
                    UInt(raw.count)
                )
            }
            return true
        }
    }

    /// Tear down the pump task and forget the surface. The display
    /// client itself is stopped separately so callers can decide
    /// whether to keep the underlying herdr pane alive across surface
    /// re-binds (e.g. panel split / move).
    func detach() {
        pumpTask?.cancel()
        pumpTask = nil
        // Acquiring the lock here drains any in-flight processOutput
        // call so callers can safely run ghostty_surface_free
        // afterwards.
        surfaceState.withLock { $0 = nil }
    }

    /// Stop everything: pump + display client + free our reference to
    /// the surface.
    func stop() {
        detach()
        displayClient.stop()
    }

    // MARK: - private

    private func startPump() {
        let stream = displayClient.output
        pumpTask = Task.detached(priority: .userInitiated) { [weak self] in
            for await chunk in stream {
                guard let self else { break }
                if Task.isCancelled { return }
                if !self.processOutput(chunk) { return }
            }
        }
    }
}
