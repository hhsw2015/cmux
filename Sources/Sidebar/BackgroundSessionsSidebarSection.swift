import CMUXZmx
import SwiftUI

/// Static action helpers for the background sidebar section. Lifted out
/// of any specific view's scope so SwiftUI sub-views (VerticalTabsSidebar
/// etc.) can pass them as `onReattach` / `onKill` without owning the
/// methods themselves.
@MainActor
enum BackgroundSessionsSidebarActions {
    static func reattach(_ entry: BackgroundSessionStore.Entry) {
        // Spawn a fresh terminal panel pointed at the detached session.
        // We don't know which workspace is in front from here; punt to a
        // notification the host responds to with the focused workspace.
        NotificationCenter.default.post(
            name: .sessionPersistenceReattachRequested,
            object: nil,
            userInfo: ["entry": entry]
        )
    }

    static func kill(_ entry: BackgroundSessionStore.Entry) {
        let name = entry.sessionName
        BackgroundSessionStore.shared.remove(sessionName: name)
        Task.detached(priority: .utility) {
            guard let backend = SessionDaemonResolver.shared.activeBackend() else { return }
            try? await backend.kill(name, force: true)
        }
    }
}

extension Notification.Name {
    /// Posted from the sidebar background section so the host (ContentView)
    /// can spawn a panel in the focused workspace.
    static let sessionPersistenceReattachRequested =
        Notification.Name("com.cmuxterm.sessionPersistence.reattachRequested")
}

/// Sidebar section that lists every detached zmx/tsm session whose cmux
/// panel was closed but whose daemon process is still alive. Clicking a
/// row asks the host to reopen it as a panel.
///
/// Lives behind `SessionPersistenceFeature.background`; the sidebar
/// host gates the section on `effective(.background)`.
struct BackgroundSessionsSidebarSection: View {
    @ObservedObject var store: BackgroundSessionStore
    let onReattach: (BackgroundSessionStore.Entry) -> Void
    let onKill: (BackgroundSessionStore.Entry) -> Void

    var body: some View {
        if store.sessions.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: "tray.full")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(String(
                        localized: "sidebar.background.title",
                        defaultValue: "Background"
                    ))
                    .font(.caption.smallCaps())
                    .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Text("\(store.sessions.count)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .padding(.horizontal, 10)
                .padding(.top, 6)

                ForEach(store.sessions) { entry in
                    BackgroundSessionRow(
                        entry: entry,
                        onReattach: { onReattach(entry) },
                        onKill: { onKill(entry) }
                    )
                }
            }
        }
    }
}

private struct BackgroundSessionRow: View {
    let entry: BackgroundSessionStore.Entry
    let onReattach: () -> Void
    let onKill: () -> Void

    var body: some View {
        Button(action: onReattach) {
            HStack(spacing: 6) {
                Image(systemName: "bolt.horizontal.circle")
                    .foregroundStyle(.yellow)
                    .font(.caption)
                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.sessionName)
                        .font(.caption.monospaced())
                        .lineLimit(1)
                    Text(relativeAgeText(for: entry.detachedAt))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(String(
                localized: "sidebar.background.reattach",
                defaultValue: "Reattach in new panel"
            )) { onReattach() }
            Divider()
            Button(role: .destructive) { onKill() } label: {
                Text(String(
                    localized: "sidebar.background.kill",
                    defaultValue: "Kill session"
                ))
            }
        }
        .accessibilityIdentifier("BackgroundSessionRow_\(entry.sessionName)")
    }

    private func relativeAgeText(for date: Date) -> String {
        let interval = Date().timeIntervalSince(date)
        if interval < 60 {
            return "<1m"
        }
        if interval < 3600 {
            return "\(Int(interval / 60))m"
        }
        if interval < 86_400 {
            return "\(Int(interval / 3600))h"
        }
        return "\(Int(interval / 86_400))d"
    }
}
