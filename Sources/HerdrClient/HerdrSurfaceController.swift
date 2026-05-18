import Foundation
import GhosttyKit

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
/// Scope today (B6): skeleton — owns the lifecycle and the byte-pump
/// task. Hookup to a specific cmux terminal panel (replacing the
/// panel's local PTY-driven surface with one driven by this controller)
/// is the follow-up integration in the next step. The current code is
/// runnable in tests and demonstrates the flow end-to-end without yet
/// wiring into bonsplit.
@MainActor
final class HerdrSurfaceController {
    let displayClient: HerdrDisplayClient
    private(set) var surface: ghostty_surface_t?
    private var pumpTask: Task<Void, Never>?

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
        self.surface = surface
        startPump()
    }

    /// Forward a keystroke / pasted text from the Ghostty side back to
    /// the herdr pane. cmux's existing key-event plumbing should call
    /// this when the surface is owned by a HerdrSurfaceController
    /// instead of feeding the local PTY.
    func sendInput(_ data: Data) {
        displayClient.send(data)
    }

    /// Tear down the pump task and forget the surface. The display
    /// client itself is stopped separately so callers can decide
    /// whether to keep the underlying herdr pane alive across surface
    /// re-binds (e.g. panel split / move).
    func detach() {
        pumpTask?.cancel()
        pumpTask = nil
        surface = nil
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
        pumpTask = Task { [weak self] in
            for await chunk in stream {
                guard let self else { break }
                guard let surface = self.surface else { continue }
                chunk.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                    guard let base = raw.baseAddress else { return }
                    let cChars = base.assumingMemoryBound(to: CChar.self)
                    ghostty_surface_process_output(
                        surface,
                        cChars,
                        UInt(raw.count)
                    )
                }
            }
        }
    }
}
