#if DEBUG
import AppKit
import Foundation
import GhosttyKit

/// Append a line to /tmp/herdr-debug.log with a timestamp. Bypasses
/// NSLog because the unified-log filter we tried wasn't surfacing
/// messages from the cmux DEV bundle reliably during the resize
/// debugging session.
private func herdrDebugTrace(_ message: String) {
    let timestamp = ISO8601DateFormatter().string(from: Date())
    let line = "[\(timestamp)] [HerdrPaneDebugWindow] \(message)\n"
    if let data = line.data(using: .utf8) {
        if let handle = FileHandle(forWritingAtPath: "/tmp/herdr-debug.log") {
            handle.seekToEndOfFile()
            try? handle.write(contentsOf: data)
            try? handle.close()
        } else {
            FileManager.default.createFile(atPath: "/tmp/herdr-debug.log", contents: data)
        }
    }
}

/// DEBUG-only window that exercises the full herdr cmux integration
/// stack against a localhost daemon and dumps incoming PTY bytes as a
/// hex+ASCII view. Validates B1–B6 wiring inside the actual cmux app
/// process (vs. the standalone shell-script PoC) before the heavier
/// Ghostty-surface integration lands.
///
/// Open from menu: Debug → Debug Windows → Herdr Pane (debug).
@MainActor
final class HerdrPaneDebugWindowController: NSWindowController, NSWindowDelegate {
    static let shared = HerdrPaneDebugWindowController()

    private let textView: NSTextView
    private let statusLabel: NSTextField
    private let connectButton: NSButton
    private let modePicker: NSSegmentedControl
    private let scrollView: NSScrollView
    private let ghosttyContainer: NSView

    private var displayClient: HerdrDisplayClient?
    private var surfaceController: HerdrSurfaceController?
    private var terminalSurface: TerminalSurface?
    private var ioCallbackContext: UnsafeMutableRawPointer?
    private var pumpTask: Task<Void, Never>?
    private var bytesReceived: Int = 0
    private var paneId: String?
    private var currentHost: HerdrHost?
    private var apiClient: HerdrApiClient?
    private var lastReportedSize: (cols: UInt16, rows: UInt16)?
    private var resizeObserver: NSObjectProtocol?
    private var resizeDebounceTask: Task<Void, Never>?

    private init(unused: Void = ()) {
        // Build UI.
        let scroll = NSScrollView(frame: .zero)
        scroll.hasVerticalScroller = true
        scroll.autoresizingMask = [.width, .height]

        let tv = NSTextView(frame: .zero)
        tv.isEditable = false
        tv.isSelectable = true
        tv.font = NSFont.userFixedPitchFont(ofSize: 11)
        tv.autoresizingMask = [.width]
        tv.textContainer?.containerSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        tv.textContainer?.widthTracksTextView = true
        scroll.documentView = tv
        self.textView = tv
        self.scrollView = scroll

        let status = NSTextField(labelWithString: "idle")
        status.font = NSFont.systemFont(ofSize: 11)
        self.statusLabel = status

        let button = NSButton(title: "Connect to localhost", target: nil, action: nil)
        self.connectButton = button

        let picker = NSSegmentedControl(labels: ["Hex dump", "Ghostty"], trackingMode: .selectOne, target: nil, action: nil)
        picker.selectedSegment = 1   // default to Ghostty surface
        self.modePicker = picker

        let container = NSView(frame: .zero)
        container.translatesAutoresizingMaskIntoConstraints = false
        container.wantsLayer = true
        // Paint the container with the same composited terminal
        // background color cmux uses for its panel root view. This
        // restores the colored translucent fill that's normally
        // produced by the WindowBackdropPolicy modifier inside the
        // SwiftUI workspace root — we don't have that hierarchy here
        // so we paint the same color directly on the AppKit view.
        let snapshot = WindowAppearanceSnapshot.currentFromUserDefaults(
            app: GhosttyApp.shared
        )
        container.layer?.backgroundColor = snapshot.compositedTerminalBackgroundColor.cgColor
        self.ghosttyContainer = container

        let bar = NSStackView(views: [button, picker, status])
        bar.orientation = .horizontal
        bar.spacing = 12

        let root = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 520))
        bar.translatesAutoresizingMaskIntoConstraints = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(bar)
        root.addSubview(scroll)
        root.addSubview(container)
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: root.topAnchor, constant: 8),
            bar.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            bar.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            scroll.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),
            container.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: 8),
            container.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            container.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            container.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),
        ])
        // Default visibility tracks the picker's initial selection.
        scroll.isHidden = true   // Ghostty selected
        container.isHidden = false

        let win = NSWindow(
            contentRect: root.frame,
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        win.title = "Herdr Pane (debug)"
        win.contentView = root
        win.isReleasedWhenClosed = false
        // Match cmux main-window chrome so the Ghostty surface inside
        // looks visually identical to a regular cmux terminal panel:
        // transparent window background + blur (driven by the same
        // ghostty config knobs as the main app).
        win.isOpaque = false
        win.backgroundColor = .clear
        win.titlebarAppearsTransparent = true
        win.titleVisibility = .visible

        super.init(window: win)
        win.delegate = self
        button.target = self
        button.action = #selector(connectClicked(_:))
        picker.target = self
        picker.action = #selector(modeChanged(_:))
    }

    @objc private func modeChanged(_ sender: NSSegmentedControl) {
        let useGhostty = sender.selectedSegment == 1
        ghosttyContainer.isHidden = !useGhostty
        scrollView.isHidden = useGhostty
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func showAndFocus() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        // Apply the SAME backdrop plan cmux uses for its main windows
        // so the debug pane visually matches a regular cmux terminal:
        // background-opacity, background-blur, transparent titlebar,
        // window glass / vibrancy — all driven by the user's existing
        // WindowAppearanceSnapshot config (which itself sources from
        // Ghostty's config.toml).
        if let win = window {
            let snapshot = WindowAppearanceSnapshot.currentFromUserDefaults(
                app: GhosttyApp.shared
            )
            _ = WindowBackdropController.apply(snapshot: snapshot, to: win)
        }
    }

    func windowWillClose(_ notification: Notification) {
        teardown()
    }

    @objc private func connectClicked(_ sender: NSButton) {
        if displayClient != nil {
            teardown()
            sender.title = "Connect to localhost"
            statusLabel.stringValue = "idle"
            return
        }
        sender.isEnabled = false
        statusLabel.stringValue = "connecting..."
        Task { [weak self] in
            await self?.connect()
            await MainActor.run { sender.isEnabled = true }
        }
    }

    private func connect() async {
        let host = HerdrHost.localhost()
        currentHost = host
        let exec = (("~/.local/bin/herdr-cmux") as NSString).expandingTildeInPath
        guard FileManager.default.isExecutableFile(atPath: exec) else {
            statusLabel.stringValue = "missing binary at \(exec) — build hhsw2015/herdr fork"
            return
        }
        do {
            // 1. workspace.list → grab any existing workspace's first pane,
            //    or create a fresh one if none exist.
            let backend = try HerdrBackend(host: host, executablePath: exec)
            try await backend.start()
            defer { Task { await backend.close() } }
            let sessions = try await backend.listSessions()
            let workspaceId: String
            if let first = sessions.first {
                workspaceId = first.name
            } else {
                let api = HerdrApiClient(transport: LocalUDSTransport(
                    socketPath: host.localApiSocketPath
                ))
                try await api.start()
                let r = try await api.request(
                    method: "workspace.create",
                    params: ["focus": false, "label": "cmux-debug"]
                )
                let ws = r["workspace"] as? [String: Any]
                workspaceId = ws?["workspace_id"] as? String ?? ""
                await api.close()
                guard !workspaceId.isEmpty else {
                    statusLabel.stringValue = "workspace.create returned no id"
                    return
                }
            }

            // 2. pane.list under that workspace, take the first.
            let api = HerdrApiClient(transport: LocalUDSTransport(
                socketPath: host.localApiSocketPath
            ))
            try await api.start()
            // Keep this client alive for the duration of the connection
            // so we can call pane.resize on window resize. teardown()
            // will close it.
            self.apiClient = api
            let panesResp = try await api.request(
                method: "pane.list",
                params: ["workspace_id": workspaceId]
            )
            guard
                let panes = panesResp["panes"] as? [[String: Any]],
                let pane = panes.first,
                let terminalId = pane["terminal_id"] as? String,
                let paneIdValue = pane["pane_id"] as? String
            else {
                statusLabel.stringValue = "no panes in workspace \(workspaceId)"
                return
            }
            self.paneId = paneIdValue

            // 3. Build a HerdrSurfaceController that the cmux IME /
            //    mouse / keyboard plumbing can call back into for input.
            //    We deliberately do NOT start the controller's pump —
            //    our local startPump() is the single AsyncStream
            //    consumer and tees each chunk into both the hex dump
            //    and ghostty_surface_process_output(currentSurface, ...).
            //
            //    Note: HerdrDisplayClient is constructed below AFTER
            //    we know the actual cmux surface size. Spawning the
            //    raw-pty-attach subprocess at the wrong cols/rows
            //    (the historical 80x24 default) caused the first frame
            //    to render at the daemon's pre-resize layout and look
            //    visibly broken until the user dragged the window to
            //    trigger a resize.
            let surfaceOnly = TerminalSurface(
                tabId: UUID(),
                context: GHOSTTY_SURFACE_CONTEXT_WINDOW,
                configTemplate: nil
            )
            // External IO bindings are wired up once we have the
            // controller (which depends on the display client, which
            // depends on the surface size — a chicken/egg we resolve
            // by binding before the display client exists. The
            // controller's controller field is weak; until the display
            // client is set on it via init below, sendInput is a no-op.
            terminalSurface = surfaceOnly
            mountTerminalSurface(surfaceOnly)
            // Paint surface + window backgrounds the same way cmux's
            // own panels do — driven by the ghostty config's
            // background-opacity / background-color / blur. The
            // TerminalSurface-level applyWindowBackgroundIfActive
            // delegates internally to the surfaceView's
            // applySurfaceBackground; we just kick it off so the host
            // layer fill installs correctly.
            surfaceOnly.applyWindowBackgroundIfActive()

            // 4. Wait until Ghostty has actually built the surface and
            //    sized it from the visible NSView. Up to ~500 ms.
            var initialCols: UInt16 = 80
            var initialRows: UInt16 = 24
            for _ in 0..<25 {
                if let ghosttySurface = surfaceOnly.surface {
                    let size = ghostty_surface_size(ghosttySurface)
                    if size.columns > 0 && size.rows > 0 {
                        initialCols = size.columns
                        initialRows = size.rows
                        break
                    }
                }
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
            herdrDebugTrace("initial surface size cols=\(initialCols) rows=\(initialRows)")

            // 5. Now spawn HerdrDisplayClient with the correct initial
            //    cols/rows so the very first frame the shell paints
            //    matches the visible grid.
            let client = HerdrDisplayClient(
                host: host,
                terminalId: terminalId,
                executablePath: exec,
                cols: initialCols,
                rows: initialRows
            )
            try await client.start()
            self.displayClient = client
            statusLabel.stringValue = "connected: \(terminalId) (0 bytes)"
            connectButton.title = "Disconnect"

            // 6. Wire the controller + io_write_cb now that the display
            //    client exists. Before this point the surface was
            //    mounted but had no input target; that's fine because
            //    no shell output had arrived yet either.
            let controller = HerdrSurfaceController(displayClient: client)
            self.surfaceController = controller
            let ctxBox = HerdrIoCallbackContextBox(controller: controller)
            let ctxRaw = Unmanaged.passRetained(ctxBox).toOpaque()
            ioCallbackContext = ctxRaw
            surfaceOnly.configureExternalIo(.init(
                writeCb: herdrPaneDebugWindowWriteCallback,
                userdata: ctxRaw
            ))

            installResizeObserver()
            startPump()
        } catch {
            statusLabel.stringValue = "error: \(error)"
            await teardown()
        }
    }

    private func startPump() {
        guard let client = displayClient else { return }
        let stream = client.output
        pumpTask = Task { [weak self] in
            for await chunk in stream {
                guard let self else { break }
                self.append(bytes: chunk)
            }
        }
    }

    private func append(bytes: Data) {
        bytesReceived += bytes.count
        statusLabel.stringValue = "connected (\(bytesReceived) bytes)"

        // Tee 1: hex dump (visible when picker is on "Hex dump").
        let line = Self.hexDump(bytes)
        textView.textStorage?.append(NSAttributedString(
            string: line,
            attributes: [
                .font: NSFont.userFixedPitchFont(ofSize: 11) ?? NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor.textColor,
            ]
        ))
        textView.scrollToEndOfDocument(nil)

        // Tee 2: feed cmux TerminalSurface's underlying ghostty surface
        // so the visible Ghostty rendering picks up the same bytes.
        if let surface = terminalSurface?.surface {
            bytes.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                guard let base = raw.baseAddress else { return }
                let cChars = base.assumingMemoryBound(to: CChar.self)
                ghostty_surface_process_output(surface, cChars, UInt(raw.count))
            }
        }
    }

    /// Embed the cmux GhosttySurfaceScrollView (which wraps the
    /// GhosttyNSView) into our debug window. This is what gives us
    /// the full cmux IME / mouse / paste / focus stack for free.
    private func mountTerminalSurface(_ surface: TerminalSurface) {
        let hosted = surface.hostedView
        hosted.translatesAutoresizingMaskIntoConstraints = false
        ghosttyContainer.subviews.forEach { $0.removeFromSuperview() }
        ghosttyContainer.addSubview(hosted)
        NSLayoutConstraint.activate([
            hosted.topAnchor.constraint(equalTo: ghosttyContainer.topAnchor),
            hosted.leadingAnchor.constraint(equalTo: ghosttyContainer.leadingAnchor),
            hosted.trailingAnchor.constraint(equalTo: ghosttyContainer.trailingAnchor),
            hosted.bottomAnchor.constraint(equalTo: ghosttyContainer.bottomAnchor),
        ])
    }

    /// Watch the window so we can forward grid-size changes to the
    /// herdr daemon's PTY via `pane.resize`. Without this the shell
    /// renders for the original 80x24 grid and prompts wrap or
    /// position incorrectly when the window is smaller.
    ///
    /// We listen on NSWindow.didResize and on a periodic poll during
    /// live resize so the daemon's PTY follows the user's drag in real
    /// time rather than only at the end. ghostty_surface_size() always
    /// reports the current grid the renderer is using, so we use that
    /// as the source of truth (no need to convert pixels → cells
    /// ourselves).
    private func installResizeObserver() {
        guard let window else {
            herdrDebugTrace("installResizeObserver: no window yet")
            return
        }
        if let resizeObserver {
            NotificationCenter.default.removeObserver(resizeObserver)
        }
        resizeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            herdrDebugTrace("window didResize")
            self?.scheduleResize()
        }
        // Fire a deferred initial resize so the daemon picks up the
        // actual visible grid (not the 80x24 default we passed at
        // attach). 200 ms gives Ghostty time to mount + size its
        // surface in viewDidMoveToWindow.
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 200_000_000)
            await MainActor.run { self?.forwardCurrentSize() }
        }
    }

    private func scheduleResize() {
        // Debounce: wait a short tick after the last frame change so we
        // don't spam pane.resize during an ongoing drag.
        resizeDebounceTask?.cancel()
        resizeDebounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 80_000_000) // 80 ms
            await MainActor.run { self?.forwardCurrentSize() }
        }
    }

    private func forwardCurrentSize() {
        guard let surface = terminalSurface?.surface,
              let paneId,
              let host = currentHost
        else {
            herdrDebugTrace("forwardCurrentSize prereqs missing surface=\(terminalSurface?.surface != nil) paneId=\(self.paneId != nil) host=\(currentHost != nil)")
            return
        }
        let size = ghostty_surface_size(surface)
        herdrDebugTrace("surface size cols=\(size.columns) rows=\(size.rows) w=\(size.width_px) h=\(size.height_px) cw=\(size.cell_width_px) ch=\(size.cell_height_px)")
        let cols = size.columns
        let rows = size.rows
        guard cols > 0, rows > 0 else { return }
        if let last = lastReportedSize, last.cols == cols, last.rows == rows {
            herdrDebugTrace("size unchanged \(cols)x\(rows), skip")
            return
        }
        lastReportedSize = (cols, rows)
        // herdr's API socket is one-request-per-connection (the server
        // reads a single line, dispatches, then closes). So each
        // pane.resize gets a fresh UDS connection rather than reusing
        // a long-lived HerdrApiClient — the latter only works for the
        // events.subscribe stream.
        let socketPath = host.localApiSocketPath
        Task.detached(priority: .userInitiated) {
            await Self.sendOneShotPaneResize(
                socketPath: socketPath,
                paneId: paneId,
                cols: cols,
                rows: rows,
                cellWidthPx: size.cell_width_px,
                cellHeightPx: size.cell_height_px
            )
        }
    }

    /// One-shot JSON-RPC pane.resize over a fresh UDS connection. Logs
    /// success/failure to the herdr debug trace. Off the main actor so
    /// the blocking POSIX socket calls don't stall the UI.
    private static func sendOneShotPaneResize(
        socketPath: String,
        paneId: String,
        cols: UInt16,
        rows: UInt16,
        cellWidthPx: UInt32,
        cellHeightPx: UInt32
    ) async {
        let envelope: [String: Any] = [
            "id": "cmux_resize_\(Int(Date().timeIntervalSince1970 * 1000))",
            "method": "pane.resize",
            "params": [
                "pane_id": paneId,
                "cols": Int(cols),
                "rows": Int(rows),
                "cell_width_px": Int(cellWidthPx),
                "cell_height_px": Int(cellHeightPx),
            ],
        ]
        guard var line = try? JSONSerialization.data(withJSONObject: envelope) else {
            await MainActor.run {
                herdrDebugTrace("pane.resize JSON encode failed")
            }
            return
        }
        line.append(0x0A)

        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            await MainActor.run {
                herdrDebugTrace("pane.resize socket() errno=\(errno)")
            }
            return
        }
        defer { _ = Darwin.close(fd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8)
        let maxLen = MemoryLayout.size(ofValue: addr.sun_path)
        guard pathBytes.count < maxLen else {
            await MainActor.run {
                herdrDebugTrace("pane.resize socket path too long")
            }
            return
        }
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
        guard connectResult == 0 else {
            let err = errno
            await MainActor.run {
                herdrDebugTrace("pane.resize connect failed errno=\(err)")
            }
            return
        }

        let writeResult = line.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Int32 in
            guard let base = raw.baseAddress else { return -1 }
            var written = 0
            while written < raw.count {
                let n = Darwin.write(fd, base.advanced(by: written), raw.count - written)
                if n < 0 { return errno }
                if n == 0 { return -1 }
                written += n
            }
            return 0
        }
        guard writeResult == 0 else {
            await MainActor.run {
                herdrDebugTrace("pane.resize write failed errno=\(writeResult)")
            }
            return
        }

        await MainActor.run {
            herdrDebugTrace("pane.resize OK \(cols)x\(rows)")
        }
    }

    private static func hexDump(_ data: Data) -> String {
        var out = ""
        let bytes = [UInt8](data)
        let row = 16
        var i = 0
        while i < bytes.count {
            let end = min(i + row, bytes.count)
            for j in i..<end {
                out += String(format: "%02x ", bytes[j])
            }
            for _ in end..<(i + row) { out += "   " }
            out += "  |"
            for j in i..<end {
                let b = bytes[j]
                out += (b >= 0x20 && b < 0x7f) ? String(UnicodeScalar(b)) : "."
            }
            out += "|\n"
            i += row
        }
        return out
    }

    private func teardown() {
        pumpTask?.cancel()
        pumpTask = nil
        resizeDebounceTask?.cancel()
        resizeDebounceTask = nil
        if let resizeObserver {
            NotificationCenter.default.removeObserver(resizeObserver)
        }
        resizeObserver = nil
        ghosttyContainer.postsFrameChangedNotifications = false
        displayClient?.stop()
        displayClient = nil
        surfaceController = nil
        terminalSurface = nil
        ghosttyContainer.subviews.forEach { $0.removeFromSuperview() }
        if let raw = ioCallbackContext {
            Unmanaged<HerdrIoCallbackContextBox>.fromOpaque(raw).release()
        }
        ioCallbackContext = nil
        if let api = apiClient {
            Task { await api.close() }
        }
        apiClient = nil
        paneId = nil
        currentHost = nil
        lastReportedSize = nil
        bytesReceived = 0
    }
}

/// Holds a weak reference to the controller so io_write_cb can forward
/// keystrokes back through the herdr stack. Retained by the debug
/// window through ioCallbackContext (Unmanaged); released on teardown.
private final class HerdrIoCallbackContextBox {
    weak var controller: HerdrSurfaceController?
    init(controller: HerdrSurfaceController) {
        self.controller = controller
    }
}

/// C-callable trampoline passed to TerminalSurface.configureExternalIo.
/// Ghostty calls this on the main thread when the surface needs to
/// emit bytes "into the PTY"; we instead push them through the herdr
/// display client.
private let herdrPaneDebugWindowWriteCallback: ghostty_io_write_cb = { (ud, ptr, len) in
    guard let ud, let ptr, len > 0 else { return }
    let ctx = Unmanaged<HerdrIoCallbackContextBox>.fromOpaque(ud).takeUnretainedValue()
    let buffer = UnsafeBufferPointer(
        start: UnsafeRawPointer(ptr).assumingMemoryBound(to: UInt8.self),
        count: Int(len)
    )
    let data = Data(buffer)
    Task { @MainActor in
        ctx.controller?.sendInput(data)
    }
}
#endif
