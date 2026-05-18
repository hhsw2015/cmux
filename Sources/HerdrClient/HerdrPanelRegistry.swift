import Foundation
import GhosttyKit

/// Holds the herdr-side resources backing a panel that was created
/// with `externalIo: ` set. Without this registry the
/// HerdrSurfaceController + HerdrDisplayClient + io_callback context
/// would deallocate the moment the palette command finishes, breaking
/// every keystroke and PTY chunk.
///
/// Lifetime model:
/// - Add an entry when the panel is born.
/// - Remove (and tear down) the entry when the panel is destroyed,
///   typically from the workspace's panel lifecycle hook.
@MainActor
final class HerdrPanelRegistry {
    static let shared = HerdrPanelRegistry()

    struct Entry {
        let displayClient: HerdrDisplayClient
        let controller: HerdrSurfaceController
        /// Retained Unmanaged context for the C `io_write_cb`
        /// userdata. Released on remove(panelId:).
        let ioCallbackContext: UnsafeMutableRawPointer
        let host: HerdrHost
        let paneId: String
        let terminalId: String
        var pumpTask: Task<Void, Never>?
        var resizeObserver: NSObjectProtocol?
        var resizeDebounceTask: Task<Void, Never>?
        var lastReportedCols: UInt16?
        var lastReportedRows: UInt16?
    }

    private(set) var entries: [UUID: Entry] = [:]

    func register(panelId: UUID, entry: Entry) {
        // If the panel id collides (shouldn't happen) tear down the
        // previous entry first.
        remove(panelId: panelId)
        entries[panelId] = entry
    }

    func attachPump(panelId: UUID, task: Task<Void, Never>) {
        entries[panelId]?.pumpTask = task
    }

    func remove(panelId: UUID) {
        guard let entry = entries.removeValue(forKey: panelId) else { return }
        entry.pumpTask?.cancel()
        entry.resizeDebounceTask?.cancel()
        if let observer = entry.resizeObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        entry.displayClient.stop()
        Unmanaged<HerdrIoCallbackBox>.fromOpaque(entry.ioCallbackContext).release()
    }

    /// Update bookkeeping for an installed resize observer + the most
    /// recently reported size, so we can dedupe identical pane.resize
    /// requests.
    func setResizeObserver(panelId: UUID, observer: NSObjectProtocol) {
        entries[panelId]?.resizeObserver = observer
    }

    func setLastReportedSize(panelId: UUID, cols: UInt16, rows: UInt16) {
        entries[panelId]?.lastReportedCols = cols
        entries[panelId]?.lastReportedRows = rows
    }

    func setResizeDebounceTask(panelId: UUID, task: Task<Void, Never>) {
        entries[panelId]?.resizeDebounceTask?.cancel()
        entries[panelId]?.resizeDebounceTask = task
    }

    func entry(panelId: UUID) -> Entry? {
        entries[panelId]
    }

    func send(panelId: UUID, bytes: Data) {
        entries[panelId]?.controller.sendInput(bytes)
    }
}

/// C-callable bridge: Ghostty hands us a userdata pointer when input
/// arrives at a manual-IO surface. We retain a HerdrIoCallbackBox per
/// panel and release on registry remove.
final class HerdrIoCallbackBox {
    weak var controller: HerdrSurfaceController?
    let panelId: UUID
    init(panelId: UUID, controller: HerdrSurfaceController) {
        self.panelId = panelId
        self.controller = controller
    }
}

/// Function-pointer compatible with `ghostty_io_write_cb`. Forwards
/// keystrokes from Ghostty back to the herdr daemon's PTY.
let herdrPanelIoWriteCallback: ghostty_io_write_cb = { (ud, ptr, len) in
    guard let ud, let ptr, len > 0 else { return }
    let box = Unmanaged<HerdrIoCallbackBox>.fromOpaque(ud).takeUnretainedValue()
    let buffer = UnsafeBufferPointer(
        start: UnsafeRawPointer(ptr).assumingMemoryBound(to: UInt8.self),
        count: Int(len)
    )
    let data = Data(buffer)
    Task { @MainActor in
        box.controller?.sendInput(data)
    }
}
