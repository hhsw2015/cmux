import SwiftUI

/// Sidebar section that lists every registered herdr host. Each host
/// row is collapsible; expanding it triggers a `workspace.list` fetch
/// (cached per host) and reveals the host's herdr workspaces. Click
/// a workspace row to open it as a herdr-backed cmux workspace.
///
/// Hidden entirely when no hosts are registered (HostRegistry always
/// has localhost, so this is rarely empty).
struct HerdrHostsSidebarSection: View {
    @ObservedObject var hostRegistry: HostRegistry
    @ObservedObject var workspaceListStore: HerdrWorkspaceListStore
    let onOpenWorkspace: (HerdrHost, String) -> Void

    @State private var expandedHosts: Set<UUID> = []
    @State private var pendingKill: PendingKill?

    private struct PendingKill: Identifiable {
        let host: HerdrHost
        let workspace: HerdrWorkspaceSummary
        var id: String { "\(host.id.uuidString)/\(workspace.workspaceId)" }
    }

    var body: some View {
        if hostRegistry.hosts.isEmpty {
            EmptyView()
        } else {
            sectionContent
                .task(id: hostRegistry.hosts.map(\.id)) {
                    await keepEventsFlowing()
                }
                .alert(item: $pendingKill) { kill in
                    Alert(
                        title: Text(String(
                            localized: "sidebar.herdr.kill.title",
                            defaultValue: "Kill workspace?"
                        )),
                        message: Text(String(
                            localized: "sidebar.herdr.kill.message",
                            defaultValue: "All processes in “\(kill.workspace.label)” on \(kill.host.displayName) will be terminated."
                        )),
                        primaryButton: .destructive(Text(String(
                            localized: "sidebar.herdr.kill.confirm",
                            defaultValue: "Kill"
                        ))) {
                            killWorkspace(host: kill.host, workspaceId: kill.workspace.workspaceId)
                        },
                        secondaryButton: .cancel()
                    )
                }
        }
    }

    private var sectionContent: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "rectangle.split.3x1")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(String(
                    localized: "sidebar.herdr.title",
                    defaultValue: "Herdr"
                ))
                .font(.caption.smallCaps())
                .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Text("\(hostRegistry.hosts.count)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .padding(.horizontal, 10)
            .padding(.top, 6)

            ForEach(hostRegistry.hosts) { host in
                HerdrHostRow(
                    host: host,
                    isExpanded: expandedHosts.contains(host.id),
                    isLoading: workspaceListStore.isLoading(host: host),
                    workspaces: workspaceListStore.workspaces(forHost: host),
                    lastError: workspaceListStore.lastErrorByHost[host.id],
                    onToggle: {
                        toggleExpansion(host: host)
                    },
                    onRefresh: {
                        workspaceListStore.refresh(host: host)
                    },
                    onOpenWorkspace: { workspaceId in
                        onOpenWorkspace(host, workspaceId)
                    },
                    onKillWorkspace: { ws in
                        pendingKill = PendingKill(host: host, workspace: ws)
                    }
                )
            }
        }
    }

    /// While the section is mounted, hold a refcount on the per-host
    /// event pump so workspace.created/closed/focused events drive
    /// `HerdrWorkspaceListStore` invalidation and the sidebar count
    /// badges stay live without manual refresh.
    private func keepEventsFlowing() async {
        let hosts = hostRegistry.hosts
        for host in hosts {
            await HerdrEventPump.shared.acquire(host: host)
        }
        do {
            try await Task.sleep(nanoseconds: .max)
        } catch {
            // Cancelled by .task lifecycle (view disappeared or
            // hostRegistry.hosts changed). Fall through to release.
        }
        for host in hosts {
            await HerdrEventPump.shared.release(host: host)
        }
    }

    private func killWorkspace(host: HerdrHost, workspaceId: String) {
        Task.detached {
            await HerdrOneShotRPC.send(
                host: host,
                method: "workspace.close",
                params: ["workspace_id": workspaceId]
            )
            // Refresh shortly after so the row drops out even if the
            // workspace.closed event hasn't propagated yet (the pump
            // also invalidates, but races are cheap to handle).
            try? await Task.sleep(nanoseconds: 250_000_000)
            await HerdrWorkspaceListStore.shared.refresh(host: host)
        }
    }

    private func toggleExpansion(host: HerdrHost) {
        if expandedHosts.contains(host.id) {
            expandedHosts.remove(host.id)
            return
        }
        expandedHosts.insert(host.id)
        // Lazy fetch on first expand. If we already have a cached
        // result, the user can hit refresh from the host row.
        if workspaceListStore.workspaces(forHost: host).isEmpty {
            workspaceListStore.refresh(host: host)
        }
    }
}

private struct HerdrHostRow: View {
    let host: HerdrHost
    let isExpanded: Bool
    let isLoading: Bool
    let workspaces: [HerdrWorkspaceSummary]
    let lastError: String?
    let onToggle: () -> Void
    let onRefresh: () -> Void
    let onOpenWorkspace: (String) -> Void
    let onKillWorkspace: (HerdrWorkspaceSummary) -> Void

    var body: some View {
        VStack(spacing: 0) {
            Button(action: onToggle) {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    Image(systemName: host.isLocalhost ? "desktopcomputer" : "network")
                        .foregroundStyle(host.isLocalhost ? Color.secondary : Color.blue)
                        .font(.caption)
                    Text(host.displayName)
                        .font(.caption)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if isLoading {
                        ProgressView()
                            .controlSize(.mini)
                            .scaleEffect(0.7)
                    } else if !workspaces.isEmpty {
                        Text("\(workspaces.count)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 3)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("HerdrHostRow_\(host.id.uuidString)")
            .contextMenu {
                Button(String(
                    localized: "sidebar.herdr.refresh",
                    defaultValue: "Refresh"
                )) { onRefresh() }
            }

            if isExpanded {
                if let error = lastError {
                    Text(error)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                        .padding(.horizontal, 10)
                        .padding(.bottom, 3)
                } else if workspaces.isEmpty && !isLoading {
                    Text(String(
                        localized: "sidebar.herdr.empty",
                        defaultValue: "No workspaces"
                    ))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 26)
                    .padding(.bottom, 3)
                } else {
                    ForEach(workspaces) { ws in
                        HerdrWorkspaceRow(
                            workspace: ws,
                            onOpen: { onOpenWorkspace(ws.workspaceId) },
                            onKill: { onKillWorkspace(ws) }
                        )
                    }
                }
            }
        }
    }
}

private struct HerdrWorkspaceRow: View {
    let workspace: HerdrWorkspaceSummary
    let onOpen: () -> Void
    let onKill: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 6) {
                Image(systemName: "rectangle.grid.2x2")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(workspace.label)
                        .font(.caption)
                        .lineLimit(1)
                    if workspace.paneCount > 0 {
                        Text("\(workspace.paneCount) pane\(workspace.paneCount == 1 ? "" : "s")")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.leading, 26)
            .padding(.trailing, 10)
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("HerdrWorkspaceRow_\(workspace.workspaceId)")
        .contextMenu {
            Button(String(
                localized: "sidebar.herdr.openWorkspace",
                defaultValue: "Open"
            )) { onOpen() }
            Divider()
            Button(role: .destructive) { onKill() } label: {
                Text(String(
                    localized: "sidebar.herdr.kill.menu",
                    defaultValue: "Kill workspace…"
                ))
            }
        }
    }
}
