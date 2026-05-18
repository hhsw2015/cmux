#if DEBUG
import AppKit
import Foundation
import GhosttyKit

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
        container.layer?.backgroundColor = NSColor.black.cgColor
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
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        win.title = "Herdr Pane (debug)"
        win.contentView = root
        win.isReleasedWhenClosed = false

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
                    socketPath: (("~/.config/herdr/sessions/" + host.sessionName + "/herdr.sock") as NSString)
                        .expandingTildeInPath
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
                socketPath: (("~/.config/herdr/sessions/" + host.sessionName + "/herdr.sock") as NSString)
                    .expandingTildeInPath
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

            // 3. Spawn HerdrDisplayClient against that terminal id.
            let client = HerdrDisplayClient(
                host: host,
                terminalId: terminalId,
                executablePath: exec,
                cols: 80,
                rows: 24
            )
            try await client.start()
            self.displayClient = client
            statusLabel.stringValue = "connected: \(terminalId) (0 bytes)"
            connectButton.title = "Disconnect"

            // 4. Build a HerdrSurfaceController that the cmux IME / mouse
            //    / keyboard plumbing can call back into for input. We
            //    deliberately do NOT start the controller's pump — our
            //    local startPump() is the single AsyncStream consumer
            //    and tees each chunk into both the hex dump and
            //    ghostty_surface_process_output(currentSurface, ...).
            let controller = HerdrSurfaceController(displayClient: client)
            self.surfaceController = controller

            // 5. Spin up a real cmux TerminalSurface so the Ghostty
            //    rendering, IME, mouse, paste, etc. all work for free.
            //    Configure it with embedder-owned IO BEFORE its NSView
            //    enters the window — the surface is created lazily on
            //    viewDidMoveToWindow and reads the binding at that time.
            let ctxBox = HerdrIoCallbackContextBox(controller: controller)
            let ctxRaw = Unmanaged.passRetained(ctxBox).toOpaque()
            ioCallbackContext = ctxRaw
            let surface = TerminalSurface(
                tabId: UUID(),
                context: GHOSTTY_SURFACE_CONTEXT_WINDOW,
                configTemplate: nil
            )
            surface.configureExternalIo(.init(
                writeCb: herdrPaneDebugWindowWriteCallback,
                userdata: ctxRaw
            ))
            terminalSurface = surface
            mountTerminalSurface(surface)
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

    /// Watch the ghosttyContainer's frame so we can forward grid-size
    /// changes to the herdr daemon's PTY via `pane.resize`. Without
    /// this the shell renders for the original 80x24 grid and prompts
    /// wrap or position incorrectly when the window is smaller.
    private func installResizeObserver() {
        ghosttyContainer.postsFrameChangedNotifications = true
        if let resizeObserver {
            NotificationCenter.default.removeObserver(resizeObserver)
        }
        resizeObserver = NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification,
            object: ghosttyContainer,
            queue: .main
        ) { [weak self] _ in
            self?.scheduleResize()
        }
        // Fire once now so the daemon is sized for the initial window
        // bounds rather than the 80x24 default we passed at attach.
        scheduleResize()
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
              let api = apiClient
        else { return }
        let size = ghostty_surface_size(surface)
        let cols = size.columns
        let rows = size.rows
        guard cols > 0, rows > 0 else { return }
        if let last = lastReportedSize, last.cols == cols, last.rows == rows {
            return
        }
        lastReportedSize = (cols, rows)
        Task {
            do {
                _ = try await api.request(
                    method: "pane.resize",
                    params: [
                        "pane_id": paneId,
                        "cols": Int(cols),
                        "rows": Int(rows),
                        "cell_width_px": Int(size.cell_width_px),
                        "cell_height_px": Int(size.cell_height_px),
                    ]
                )
            } catch {
                NSLog("[HerdrPaneDebugWindow] pane.resize failed: %@", String(describing: error))
            }
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
