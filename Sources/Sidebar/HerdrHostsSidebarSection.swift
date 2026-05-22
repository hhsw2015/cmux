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
    @ObservedObject private var eventPump = HerdrEventPump.shared
    @ObservedObject private var tabRegistry = HerdrTabRegistry.shared
    let onOpenWorkspace: (HerdrHost, String) -> Void

    @AppStorage(Self.expandedHostsKey) private var expandedHostsRaw: String = ""
    private var expandedHosts: Set<UUID> {
        Set(expandedHostsRaw.split(separator: ",").compactMap { UUID(uuidString: String($0)) })
    }
    static let expandedHostsKey = "cmux.herdr.sidebar.expandedHosts"
    @State private var pendingKill: PendingKill?
    @State private var pendingRename: PendingRename?
    @State private var renameDraft: String = ""
    @State private var pendingCreate: HerdrHost?
    @State private var createDraft: String = ""

    private struct PendingKill: Identifiable {
        let host: HerdrHost
        let workspace: HerdrWorkspaceSummary
        var id: String { "\(host.id.uuidString)/\(workspace.workspaceId)" }
    }

    private struct PendingRename: Identifiable {
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
                .onReceive(NotificationCenter.default.publisher(
                    for: NSApplication.didBecomeActiveNotification
                )) { _ in
                    for host in hostRegistry.hosts {
                        workspaceListStore.refresh(host: host)
                    }
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
                .sheet(item: $pendingRename) { rename in
                    HerdrWorkspaceRenameSheet(
                        initialLabel: rename.workspace.label,
                        text: $renameDraft,
                        onConfirm: { newLabel in
                            renameWorkspace(host: rename.host, workspaceId: rename.workspace.workspaceId, newLabel: newLabel)
                            pendingRename = nil
                        },
                        onCancel: { pendingRename = nil }
                    )
                }
                .sheet(item: $pendingCreate) { host in
                    HerdrWorkspaceCreateSheet(
                        host: host,
                        text: $createDraft,
                        onConfirm: { label in
                            createWorkspace(host: host, label: label)
                            pendingCreate = nil
                        },
                        onCancel: { pendingCreate = nil }
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
                    defaultValue: "Computers"
                ))
                .font(.caption.smallCaps())
                .foregroundStyle(.secondary)
                if blockedCount > 0 {
                    HStack(spacing: 3) {
                        Circle()
                            .fill(Color.orange)
                            .frame(width: 5, height: 5)
                        Text(String(
                            localized: "sidebar.herdr.blockedBadge",
                            defaultValue: "\(blockedCount) waiting"
                        ))
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .monospacedDigit()
                    }
                    .help(String(
                        localized: "sidebar.herdr.blockedBadge.tooltip",
                        defaultValue: "Workspaces waiting for input across all your computers"
                    ))
                }
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
                    connectionState: eventPump.connectionStateByHost[host.id] ?? .idle,
                    workspaces: sortedWorkspaces(forHost: host),
                    lastError: workspaceListStore.lastErrorByHost[host.id],
                    onToggle: {
                        toggleExpansion(host: host)
                    },
                    onRefresh: {
                        workspaceListStore.refresh(host: host)
                    },
                    onNewWorkspace: {
                        createDraft = ""
                        pendingCreate = host
                    },
                    onOpenWorkspace: { workspaceId in
                        onOpenWorkspace(host, workspaceId)
                    },
                    onKillWorkspace: { ws in
                        pendingKill = PendingKill(host: host, workspace: ws)
                    },
                    onRenameWorkspace: { ws in
                        renameDraft = ws.label
                        pendingRename = PendingRename(host: host, workspace: ws)
                    },
                    isWorkspaceAttached: { workspaceId in
                        isAttached(host: host, workspaceId: workspaceId)
                    }
                )
            }
        }
    }

    /// While the section is mounted, hold a refcount on the per-host
    /// event pump so workspace.created/closed/focused events drive
    /// `HerdrWorkspaceListStore` invalidation and the sidebar count
    /// badges stay live without manual refresh. Also poll every 30s
    /// to catch agent_status changes that aren't surfaced as
    /// workspace.* events (the event pump only fires on lifecycle
    /// changes, not status flips).
    private func keepEventsFlowing() async {
        let hosts = hostRegistry.hosts
        for host in hosts {
            await HerdrEventPump.shared.acquire(host: host)
            // Prime each host once on mount so agent_status badges
            // show up before the first poll.
            workspaceListStore.refresh(host: host)
        }
        defer {
            for host in hosts {
                Task { await HerdrEventPump.shared.release(host: host) }
            }
        }
        while !Task.isCancelled {
            do {
                try await Task.sleep(nanoseconds: 30_000_000_000)
            } catch {
                return
            }
            // Skip the poll while cmux isn't the active app — saves
            // SSH bandwidth + battery when the user is in another
            // app. The event pump still delivers any layout/lifecycle
            // change immediately on the long-lived subscription, and
            // when the user comes back to cmux the next 30s tick
            // catches them up. Worst case: 30s of stale agent_status
            // when they return.
            if !NSApp.isActive { continue }
            for host in hosts {
                workspaceListStore.refresh(host: host)
            }
        }
    }

    private func createWorkspace(host: HerdrHost, label: String) {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        Task { @MainActor in
            let api = HerdrApiClient(transport: HerdrTransportFactory.make(host: host))
            do {
                try await api.start()
                defer { Task { await api.close() } }
                var params: [String: Any] = ["focus": true]
                if !trimmed.isEmpty { params["label"] = trimmed }
                let resp = try await api.request(method: "workspace.create", params: params)
                workspaceListStore.refresh(host: host)
                if let ws = resp["workspace"] as? [String: Any],
                   let id = ws["workspace_id"] as? String {
                    HerdrPanelOpener.openWorkspace(host: host, workspaceId: id)
                }
            } catch {
                cmuxDebugLog("herdr.create: \(host.displayName): \(error)")
            }
        }
    }

    private func renameWorkspace(host: HerdrHost, workspaceId: String, newLabel: String) {
        let trimmed = newLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        Task.detached {
            await HerdrOneShotRPC.send(
                host: host,
                method: "workspace.rename",
                params: ["workspace_id": workspaceId, "label": trimmed]
            )
            try? await Task.sleep(nanoseconds: 250_000_000)
            await HerdrWorkspaceListStore.shared.refresh(host: host)
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

    /// Sort workspaces by agent_status priority so the rows that
    /// most likely need attention float to the top of the host's
    /// list. Stable secondary sort by label so equal-priority
    /// rows keep a deterministic order.
    private func sortedWorkspaces(forHost host: HerdrHost) -> [HerdrWorkspaceSummary] {
        let raw = workspaceListStore.workspaces(forHost: host)
        return raw.sorted { lhs, rhs in
            let lp = priority(for: lhs.agentStatus)
            let rp = priority(for: rhs.agentStatus)
            if lp != rp { return lp < rp }
            return lhs.label.localizedCaseInsensitiveCompare(rhs.label) == .orderedAscending
        }
    }

    private func priority(for status: String?) -> Int {
        switch status?.lowercased() {
        case "blocked": return 0
        case "working": return 1
        case "done":    return 2
        case "idle":    return 3
        default:        return 4
        }
    }

    private func isAttached(host: HerdrHost, workspaceId: String) -> Bool {
        tabRegistry.allBindings.contains {
            $0.host.id == host.id && $0.workspaceId == workspaceId
        }
    }

    private var blockedCount: Int {
        hostRegistry.hosts.reduce(0) { acc, host in
            acc + workspaceListStore.workspaces(forHost: host).filter {
                $0.agentStatus?.lowercased() == "blocked"
            }.count
        }
    }

    private func toggleExpansion(host: HerdrHost) {
        var current = expandedHosts
        if current.contains(host.id) {
            current.remove(host.id)
        } else {
            current.insert(host.id)
            // Lazy fetch on first expand. If cached, the user can
            // hit refresh from the host row.
            if workspaceListStore.workspaces(forHost: host).isEmpty {
                workspaceListStore.refresh(host: host)
            }
        }
        expandedHostsRaw = current.map { $0.uuidString }.sorted().joined(separator: ",")
    }
}

private struct HerdrHostRow: View {
    let host: HerdrHost
    let isExpanded: Bool
    let isLoading: Bool
    let connectionState: HerdrEventPump.ConnectionState
    let workspaces: [HerdrWorkspaceSummary]
    let lastError: String?
    let onToggle: () -> Void
    let onRefresh: () -> Void
    let onNewWorkspace: () -> Void
    let onOpenWorkspace: (String) -> Void
    let onKillWorkspace: (HerdrWorkspaceSummary) -> Void
    let onRenameWorkspace: (HerdrWorkspaceSummary) -> Void
    let isWorkspaceAttached: (String) -> Bool

    private var connectionTint: Color {
        switch connectionState {
        case .retrying:
            return .red
        case .connecting:
            return .orange
        case .connected, .idle:
            return host.isLocalhost ? Color.secondary : Color.blue
        }
    }

    private var hostTooltipDetail: String {
        switch host.transport {
        case .localUDS:
            return "\(host.displayName) · localhost · \(host.sessionName)"
        case .sshStdio(let target):
            return "\(host.displayName) · ssh \(target) · \(host.sessionName)"
        }
    }

    private var connectionTooltip: String {
        switch connectionState {
        case .retrying(let attempt, let lastError):
            return String(
                localized: "sidebar.herdr.host.retrying",
                defaultValue: "Reconnecting (attempt \(attempt)): \(lastError)"
            )
        case .connecting:
            return String(
                localized: "sidebar.herdr.host.connecting",
                defaultValue: "Connecting…"
            )
        case .connected:
            return String(
                localized: "sidebar.herdr.host.connected",
                defaultValue: "Connected"
            )
        case .idle:
            return host.displayName
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Button(action: onToggle) {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    Image(systemName: host.isLocalhost ? "desktopcomputer" : "network")
                        .foregroundStyle(connectionTint)
                        .font(.caption)
                        .help(connectionTooltip)
                    Text(host.displayName)
                        .font(.caption)
                        .lineLimit(1)
                        .help(hostTooltipDetail)
                    Spacer(minLength: 0)
                    if isLoading {
                        ProgressView()
                            .controlSize(.mini)
                            .scaleEffect(0.7)
                    } else if !workspaces.isEmpty {
                        let blocked = workspaces.filter {
                            $0.agentStatus?.lowercased() == "blocked"
                        }.count
                        if blocked > 0 {
                            HStack(spacing: 3) {
                                Circle().fill(Color.orange)
                                    .frame(width: 5, height: 5)
                                Text("\(blocked)")
                                    .font(.caption2)
                                    .foregroundStyle(.orange)
                                    .monospacedDigit()
                            }
                        }
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
                    localized: "sidebar.herdr.newWorkspace",
                    defaultValue: "New workspace…"
                )) { onNewWorkspace() }
                Button(String(
                    localized: "sidebar.herdr.refresh",
                    defaultValue: "Refresh"
                )) { onRefresh() }
                Divider()
                Button(String(
                    localized: "sidebar.herdr.reconnect",
                    defaultValue: "Reconnect / Restart daemon"
                )) {
                    HerdrRemoteInstaller.installOnHost(host)
                }
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
                            isAttached: isWorkspaceAttached(ws.workspaceId),
                            onOpen: { onOpenWorkspace(ws.workspaceId) },
                            onKill: { onKillWorkspace(ws) },
                            onRename: { onRenameWorkspace(ws) }
                        )
                    }
                }
            }
        }
    }
}

private struct HerdrWorkspaceRow: View {
    let workspace: HerdrWorkspaceSummary
    let isAttached: Bool
    let onOpen: () -> Void
    let onKill: () -> Void
    let onRename: () -> Void

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
                        Text(String(
                            localized: "sidebar.herdr.paneCount",
                            defaultValue: "\(workspace.paneCount) panes"
                        ))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
                agentStatusBadge
            }
            .padding(.leading, 26)
            .padding(.trailing, 10)
            .padding(.vertical, 2)
            .contentShape(Rectangle())
            .background(isAttached ? Color.accentColor.opacity(0.12) : Color.clear)
            .cornerRadius(4)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("HerdrWorkspaceRow_\(workspace.workspaceId)")
        .help(agentStatusHelpText)
        .contextMenu {
            Button(String(
                localized: "sidebar.herdr.openWorkspace",
                defaultValue: "Open"
            )) { onOpen() }
            Button(String(
                localized: "sidebar.herdr.rename.menu",
                defaultValue: "Rename…"
            )) { onRename() }
            Divider()
            Button(role: .destructive) { onKill() } label: {
                Text(String(
                    localized: "sidebar.herdr.kill.menu",
                    defaultValue: "Kill workspace…"
                ))
            }
        }
    }

    @ViewBuilder
    private var agentStatusBadge: some View {
        if let color = agentStatusColor {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
        }
    }

    private var agentStatusColor: Color? {
        switch agentStatusNormalized {
        case "idle":    return Color.gray.opacity(0.5)
        case "working": return Color.green
        case "blocked": return Color.orange
        case "done":    return Color.blue
        default:        return nil
        }
    }

    private var agentStatusHelpText: String {
        switch agentStatusNormalized {
        case "idle":
            return String(localized: "sidebar.herdr.agent.idle", defaultValue: "Agent idle")
        case "working":
            return String(localized: "sidebar.herdr.agent.working", defaultValue: "Agent working")
        case "blocked":
            return String(localized: "sidebar.herdr.agent.blocked", defaultValue: "Agent waiting for input")
        case "done":
            return String(localized: "sidebar.herdr.agent.done", defaultValue: "Agent done")
        default:
            return workspace.label
        }
    }

    private var agentStatusNormalized: String {
        workspace.agentStatus?.lowercased() ?? "unknown"
    }
}

private struct HerdrWorkspaceCreateSheet: View {
    let host: HerdrHost
    @Binding var text: String
    let onConfirm: (String) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(String(
                localized: "sidebar.herdr.create.sheet.title",
                defaultValue: "New workspace on \(host.displayName)"
            ))
            .font(.headline)
            TextField(String(
                localized: "sidebar.herdr.create.placeholder",
                defaultValue: "Optional label"
            ), text: $text)
                .textFieldStyle(.roundedBorder)
                .onSubmit { onConfirm(text) }
            HStack {
                Spacer()
                Button(String(
                    localized: "sidebar.herdr.rename.cancel",
                    defaultValue: "Cancel"
                ), action: onCancel)
                .keyboardShortcut(.cancelAction)
                Button(String(
                    localized: "sidebar.herdr.create.confirm",
                    defaultValue: "Create"
                )) { onConfirm(text) }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 360)
    }
}

private struct HerdrWorkspaceRenameSheet: View {
    let initialLabel: String
    @Binding var text: String
    let onConfirm: (String) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(String(
                localized: "sidebar.herdr.rename.sheet.title",
                defaultValue: "Rename workspace"
            ))
            .font(.headline)
            TextField(initialLabel, text: $text)
                .textFieldStyle(.roundedBorder)
                .onSubmit { onConfirm(text) }
            HStack {
                Spacer()
                Button(String(
                    localized: "sidebar.herdr.rename.cancel",
                    defaultValue: "Cancel"
                ), action: onCancel)
                .keyboardShortcut(.cancelAction)
                Button(String(
                    localized: "sidebar.herdr.rename.confirm",
                    defaultValue: "Rename"
                )) { onConfirm(text) }
                .keyboardShortcut(.defaultAction)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 360)
    }
}
