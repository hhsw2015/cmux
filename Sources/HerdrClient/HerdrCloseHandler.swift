#if DEBUG
import Foundation

/// Handles cleanup when a herdr-backed terminal panel closes inside
/// cmux. Sends the matching `pane.close` RPC against the host that
/// owns the pane (tmux-style: closing a split kills the process), then
/// tears down the local registry entries so the display client and
/// io-callback box stop holding memory.
@MainActor
enum HerdrCloseHandler {
    /// Herdr pane ids whose corresponding cmux pane will be closed
    /// imminently as part of an inbound `LayoutChanged` reconcile.
    /// `handlePanelClosed` consumes these ids and skips the
    /// `pane.close` RPC for them — the remote already closed the pane,
    /// so echoing back would be wasted work and could race against
    /// other clients.
    static var suppressNextCloseFor: Set<String> = []

    /// Best-effort cleanup for a single closed panel. Safe to call for
    /// any panel — if the panel wasn't herdr-backed, this is a no-op.
    static func handlePanelClosed(panelId: UUID) {
        guard let entry = HerdrPanelRegistry.shared.entry(panelId: panelId) else {
            return
        }
        let herdrPaneId = entry.paneId
        let host = entry.host
        let socketPath = (("~/.config/herdr/sessions/" + host.sessionName + "/herdr.sock") as NSString)
            .expandingTildeInPath

        // Find any HerdrTabBinding that owned a cmux pane bound to this
        // herdr pane and drop the mapping so subsequent E2 mutation
        // lookups stop seeing a closed pane.
        for binding in HerdrTabRegistry.shared.allBindings {
            if binding.paneBindings.cmuxPaneId(forHerdrId: herdrPaneId) != nil {
                binding.paneBindings.unbind(herdrPaneId: herdrPaneId)
                if binding.paneBindings.count == 0 {
                    HerdrTabRegistry.shared.remove(key: binding.rootCmuxPaneId)
                    HerdrDividerSync.reset(bindingKey: binding.rootCmuxPaneId)
                    let bindingHost = binding.host
                    Task { await HerdrEventPump.shared.release(host: bindingHost) }
                }
            }
        }

        // Tear down local resources first so we don't leak even if the
        // RPC dispatch hangs.
        HerdrPanelRegistry.shared.remove(panelId: panelId)

        // If the close came from an inbound LayoutChanged event, the
        // remote already destroyed the pane. Skip the echo.
        if suppressNextCloseFor.remove(herdrPaneId) != nil {
            return
        }

        // Best-effort kill on the herdr side. tmux semantics: close
        // pane = kill the process.
        Task.detached {
            await sendPaneClose(socketPath: socketPath, herdrPaneId: herdrPaneId)
        }
    }

    private static func sendPaneClose(socketPath: String, herdrPaneId: String) async {
        let envelope: [String: Any] = [
            "id": "cmux_paneclose_\(Int(Date().timeIntervalSince1970 * 1000))",
            "method": "pane.close",
            "params": ["pane_id": herdrPaneId],
        ]
        guard var line = try? JSONSerialization.data(withJSONObject: envelope) else {
            return
        }
        line.append(0x0A)
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return }
        defer { _ = Darwin.close(fd) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8)
        let maxLen = MemoryLayout.size(ofValue: addr.sun_path)
        guard pathBytes.count < maxLen else { return }
        withUnsafeMutablePointer(to: &addr.sun_path) { pathPtr in
            pathPtr.withMemoryRebound(to: CChar.self, capacity: maxLen) { rebound in
                for i in 0..<pathBytes.count {
                    rebound[i] = CChar(bitPattern: pathBytes[i])
                }
                rebound[pathBytes.count] = 0
            }
        }
        let connectResult = withUnsafePointer(to: &addr) { addrPtr -> Int32 in
            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                Darwin.connect(fd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connectResult == 0 else { return }
        line.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            var written = 0
            while written < raw.count {
                let n = Darwin.write(fd, base.advanced(by: written), raw.count - written)
                if n <= 0 { return }
                written += n
            }
        }
    }
}
#endif
