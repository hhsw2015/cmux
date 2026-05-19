#if DEBUG
import AppKit
import SwiftUI

/// Debug menu entry for inspecting HerdrEventPump live state during
/// dogfood. Shows per-host connection state with retry detail and a
/// scrolling list of the last 200 events. Read-only; no actions.
final class HerdrEventPumpDebugWindowController: NSWindowController, NSWindowDelegate {
    static let shared = HerdrEventPumpDebugWindowController()

    private init() {
        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 480),
            styleMask: [.titled, .closable, .resizable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        window.title = String(
            localized: "debug.herdrEventPump.title",
            defaultValue: "Herdr Event Pump Debug"
        )
        window.titleVisibility = .visible
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.identifier = NSUserInterfaceItemIdentifier("cmux.herdrEventPumpDebug")
        window.center()
        window.contentView = NSHostingView(rootView: HerdrEventPumpDebugView())
        AppDelegate.shared?.applyWindowDecorations(to: window)
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func show() {
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }
}

private struct HerdrEventPumpDebugView: View {
    @ObservedObject private var pump = HerdrEventPump.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("Connection state")
            connectionTable

            sectionHeader("Recent events (newest first)")
            eventsList
        }
        .padding(12)
        .frame(minWidth: 480, minHeight: 360)
    }

    @ViewBuilder
    private func sectionHeader(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
    }

    private var connectionTable: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(connectionRows, id: \.0) { row in
                HStack(spacing: 8) {
                    Circle().fill(row.2).frame(width: 8, height: 8)
                    Text(row.1)
                        .font(.system(size: 12, weight: .medium))
                    Spacer()
                    Text(row.3)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            if connectionRows.isEmpty {
                Text(verbatim: "(no hosts connected)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(8)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
    }

    private var eventsList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(pump.recentEvents, id: \.id) { (entry: HerdrEventPump.EventLogEntry) in
                    HStack(spacing: 8) {
                        Text(verbatim: formatTime(entry.timestamp))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                        Text(verbatim: entry.hostName)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.primary)
                            .frame(width: 90, alignment: .leading)
                        Text(verbatim: entry.eventName)
                            .font(.system(size: 10, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
                if pump.recentEvents.isEmpty {
                    Text(verbatim: "(no events received)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 4)
                }
            }
            .padding(8)
        }
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
        .frame(maxHeight: .infinity)
    }

    private var connectionRows: [(UUID, String, Color, String)] {
        let hosts = HostRegistry.shared.hosts
        return hosts.compactMap { host in
            let state: HerdrEventPump.ConnectionState = pump.connectionStateByHost[host.id] ?? .idle
            let color: Color
            let detail: String
            switch state {
            case .idle:
                color = .gray
                detail = "idle"
            case .connecting:
                color = .orange
                detail = "connecting"
            case .connected:
                color = .green
                detail = "connected"
            case .retrying(let attempt, let lastError):
                color = .red
                detail = "retrying #\(attempt) — \(lastError)"
            }
            return (host.id, host.displayName, color, detail)
        }
    }

    private func formatTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter.string(from: date)
    }
}
#endif
