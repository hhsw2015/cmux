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
    private let ghosttyView: HerdrGhosttyView
    private let scrollView: NSScrollView

    private var displayClient: HerdrDisplayClient?
    private var surfaceController: HerdrSurfaceController?
    private var pumpTask: Task<Void, Never>?
    private var bytesReceived: Int = 0

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

        let gv = HerdrGhosttyView()
        gv.translatesAutoresizingMaskIntoConstraints = false
        self.ghosttyView = gv

        let bar = NSStackView(views: [button, picker, status])
        bar.orientation = .horizontal
        bar.spacing = 12

        let root = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 520))
        bar.translatesAutoresizingMaskIntoConstraints = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(bar)
        root.addSubview(scroll)
        root.addSubview(gv)
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: root.topAnchor, constant: 8),
            bar.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            bar.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            scroll.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),
            gv.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: 8),
            gv.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            gv.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            gv.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),
        ])
        // Default visibility tracks the picker's initial selection.
        scroll.isHidden = true   // Ghostty selected
        gv.isHidden = false

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
        ghosttyView.isHidden = !useGhostty
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
            defer { Task { await api.close() } }
            let panesResp = try await api.request(
                method: "pane.list",
                params: ["workspace_id": workspaceId]
            )
            guard
                let panes = panesResp["panes"] as? [[String: Any]],
                let pane = panes.first,
                let terminalId = pane["terminal_id"] as? String
            else {
                statusLabel.stringValue = "no panes in workspace \(workspaceId)"
                return
            }

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

            // 4. Bind a HerdrSurfaceController so the Ghostty view (when
            //    the picker is on "Ghostty") renders the same byte
            //    stream we hex-dump in the other tab. We deliberately
            //    do NOT call controller.attach(surface:) here — that
            //    would start a second pump competing for the
            //    single-consumer AsyncStream<Data> on
            //    HerdrDisplayClient.output. Instead, our local
            //    startPump() owns the only consumer and tees each
            //    chunk into hex dump + ghostty_surface_process_output.
            let controller = HerdrSurfaceController(displayClient: client)
            self.surfaceController = controller
            ghosttyView.attachControllerWithoutPump(controller)

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

        // Tee 2: feed Ghostty surface (visible when picker is on "Ghostty").
        if let surface = ghosttyView.surface {
            bytes.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                guard let base = raw.baseAddress else { return }
                let cChars = base.assumingMemoryBound(to: CChar.self)
                ghostty_surface_process_output(surface, cChars, UInt(raw.count))
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
        displayClient?.stop()
        displayClient = nil
        bytesReceived = 0
    }
}
#endif
