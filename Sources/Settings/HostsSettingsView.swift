import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Settings page for managing herdr hosts (the machines that run a herdr
/// daemon and persist sessions). Localhost is auto-listed; user can add
/// remote SSH targets.
struct HostsSettingsView: View {
    @ObservedObject private var registry: HostRegistry = .shared
    @ObservedObject private var healthStore: HostHealthStore = .shared
    @State private var showingAdd = false
    @State private var showingAddLocalSession = false
    @State private var editing: HerdrHost?
    @State private var pendingForceRemove: PendingForceRemove?

    private struct PendingForceRemove: Identifiable {
        let host: HerdrHost
        let activeCount: Int
        var id: UUID { host.id }
    }
    @AppStorage(HerdrNotificationSettings.blockedNotificationsEnabledKey)
    private var blockedNotificationsEnabled: Bool = HerdrNotificationSettings.blockedNotificationsEnabledDefault
    @AppStorage(HerdrNotificationSettings.hostOfflineNotificationsEnabledKey)
    private var hostOfflineNotificationsEnabled: Bool = HerdrNotificationSettings.hostOfflineNotificationsEnabledDefault

    var body: some View {
        SettingsSectionHeader(
            title: String(localized: "settings.section.hosts", defaultValue: "Computers")
        )
        .settingsSearchAnchor(SettingsSearchIndex.sectionID(for: .hosts))

        SettingsCard {
            ForEach(Array(registry.hosts.enumerated()), id: \.element.id) { index, host in
                let canMoveUp = !host.isLocalhost
                    && index > 0
                    && registry.hosts[index - 1].id != HerdrHost.localhostID
                let canMoveDown = !host.isLocalhost
                    && index < registry.hosts.count - 1
                HostRow(
                    host: host,
                    health: healthStore.health(for: host.id),
                    onEdit: { editing = host },
                    onRemove: host.isLocalhost ? nil : { tryRemove(host) },
                    onMoveUp: canMoveUp ? { registry.move(id: host.id, direction: .up) } : nil,
                    onMoveDown: canMoveDown ? { registry.move(id: host.id, direction: .down) } : nil
                )
                .equatable()
                .onDrag {
                    // Localhost is pinned; refuse to start a drag.
                    if host.isLocalhost { return NSItemProvider() }
                    return NSItemProvider(object: host.id.uuidString as NSString)
                }
                .onDrop(of: [.text], isTargeted: nil) { providers in
                    handleDrop(providers: providers, beforeHostId: host.id)
                }
                if host.id != registry.hosts.last?.id {
                    Divider()
                }
            }
        }
        // Final drop zone — dropping below the last row appends to the end.
        .onDrop(of: [.text], isTargeted: nil) { providers in
            handleDrop(providers: providers, beforeHostId: nil)
        }

        VStack(alignment: .leading, spacing: 4) {
            Toggle(String(
                localized: "settings.hosts.notifyBlocked",
                defaultValue: "Notify when a workspace waits for input"
            ), isOn: $blockedNotificationsEnabled)
            Toggle(String(
                localized: "settings.hosts.notifyHostOffline",
                defaultValue: "Notify when a remote computer goes offline"
            ), isOn: $hostOfflineNotificationsEnabled)
        }
        HStack {
            Spacer()
            Menu {
                Button {
                    showingAdd = true
                } label: {
                    Text(String(
                        localized: "settings.hosts.add.remote",
                        defaultValue: "Remote SSH host…"
                    ))
                }
                Button {
                    showingAddLocalSession = true
                } label: {
                    Text(String(
                        localized: "settings.hosts.add.localSession",
                        defaultValue: "Local herdr session…"
                    ))
                }
            } label: {
                Label(
                    String(localized: "settings.hosts.add", defaultValue: "Add computer"),
                    systemImage: "plus.circle"
                )
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(.top, 8)
        .sheet(isPresented: $showingAdd) {
            AddHostSheet(onSave: { newHost, installRequested in
                registry.add(newHost)
                if installRequested {
                    HerdrRemoteInstaller.installOnHost(newHost)
                }
                showingAdd = false
            }, onCancel: { showingAdd = false })
        }
        .sheet(isPresented: $showingAddLocalSession) {
            AddLocalSessionSheet(
                onSave: { sessionName, displayName in
                    // Dedup: if a local-UDS host already targets this
                    // session name, don't create a sibling row that
                    // would point at the same socket.
                    let exists = registry.hosts.contains { existing in
                        if case .localUDS = existing.transport,
                           existing.sessionName == sessionName {
                            return true
                        }
                        return false
                    }
                    if !exists {
                        let host = HerdrHost(
                            id: UUID(),
                            displayName: displayName.isEmpty ? sessionName : displayName,
                            transport: .localUDS,
                            sessionName: sessionName,
                            addedAt: Date()
                        )
                        registry.add(host)
                    }
                    showingAddLocalSession = false
                },
                onCancel: { showingAddLocalSession = false }
            )
        }
        .sheet(item: $editing) { host in
            AddHostSheet(
                initial: host,
                onSave: { updated, installRequested in
                    registry.update(updated)
                    if installRequested {
                        HerdrRemoteInstaller.installOnHost(updated)
                    }
                    editing = nil
                },
                onCancel: { editing = nil }
            )
        }
        .alert(item: $pendingForceRemove) { pending in
            Alert(
                title: Text(String(
                    localized: "settings.hosts.removeWithActive.title",
                    defaultValue: "Remove this computer with active workspaces?"
                )),
                message: Text(String(
                    localized: "settings.hosts.removeWithActive.message",
                    defaultValue: "“\(pending.host.displayName)” has \(pending.activeCount) attached workspace(s). Removing will not close them, but cmux will lose track of which host they came from."
                )),
                primaryButton: .destructive(Text(String(
                    localized: "settings.hosts.removeWithActive.confirm",
                    defaultValue: "Remove anyway"
                ))) {
                    registry.remove(id: pending.host.id, force: true)
                },
                secondaryButton: .cancel()
            )
        }
    }

    private func tryRemove(_ host: HerdrHost) {
        switch registry.remove(id: host.id) {
        case nil:
            return
        case .localhost:
            return
        case .hasActiveBindings(let count):
            pendingForceRemove = PendingForceRemove(host: host, activeCount: count)
        }
    }

    /// Bridges a String NSItemProvider drop into HostRegistry.move(id:before:).
    /// Returns true if we consumed a recognizable host id; SwiftUI uses
    /// the return value only to suppress the "rejected" haptic on macOS.
    private func handleDrop(providers: [NSItemProvider], beforeHostId: UUID?) -> Bool {
        guard let provider = providers.first else { return false }
        provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let raw = object as? String, let dragged = UUID(uuidString: raw) else { return }
            // No-op if the user dropped a host onto itself.
            if dragged == beforeHostId { return }
            DispatchQueue.main.async {
                registry.move(id: dragged, before: beforeHostId)
            }
        }
        return true
    }
}

/// Pure value-snapshot row: no ObservableObject references below the
/// ForEach boundary. Per CLAUDE.md "snapshot boundary" rule, this lets
/// SwiftUI's diff skip body re-evaluation for rows whose inputs didn't
/// change when an unrelated host's health flips. Equatable conformance
/// is what unlocks `.equatable()`'s memoization.
private struct HostRow: View, Equatable {
    let host: HerdrHost
    let health: HostHealthStore.HostHealth
    let onEdit: () -> Void
    let onRemove: (() -> Void)?
    let onMoveUp: (() -> Void)?
    let onMoveDown: (() -> Void)?

    static func == (lhs: HostRow, rhs: HostRow) -> Bool {
        // Closures aren't Equatable; we treat closure presence as the
        // only signal (true vs nil). The inputs that drive rendering
        // are host + health.
        lhs.host == rhs.host
            && lhs.health == rhs.health
            && (lhs.onRemove == nil) == (rhs.onRemove == nil)
            && (lhs.onMoveUp == nil) == (rhs.onMoveUp == nil)
            && (lhs.onMoveDown == nil) == (rhs.onMoveDown == nil)
    }

    var body: some View {
        HStack(spacing: 12) {
            ZStack(alignment: .bottomTrailing) {
                Image(systemName: host.isLocalhost ? "laptopcomputer" : "server.rack")
                    .foregroundStyle(.secondary)
                    .frame(width: 24)
                statusDot
                    .offset(x: 2, y: 2)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(host.displayName)
                    .font(.body)
                Text(transportSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let onMoveUp {
                Button(action: onMoveUp) {
                    Image(systemName: "chevron.up")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(String(
                    localized: "settings.hosts.moveUp",
                    defaultValue: "Move up"
                ))
            }
            if let onMoveDown {
                Button(action: onMoveDown) {
                    Image(systemName: "chevron.down")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(String(
                    localized: "settings.hosts.moveDown",
                    defaultValue: "Move down"
                ))
            }
            Button(action: onEdit) {
                Image(systemName: "pencil")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(String(
                localized: "settings.hosts.edit",
                defaultValue: "Edit computer"
            ))
            if let onRemove {
                Button(role: .destructive, action: onRemove) {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(String(
                    localized: "settings.hosts.remove",
                    defaultValue: "Remove"
                ))
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 12)
    }

    private var transportSummary: String {
        switch host.transport {
        case .localUDS:
            return "session: \(host.sessionName) · local socket"
        case .sshStdio(let target, _, _, let sshExe, _):
            let prefix = (sshExe.map { (($0 as NSString).lastPathComponent == "sshpass") ? "sshpass " : "" } ?? "")
            return "\(prefix)ssh: \(target) · session: \(host.sessionName)"
        }
    }

    /// Small colored dot indicating last-known connection state. Stays
    /// invisible until at least one probe/connect has happened so the
    /// row doesn't broadcast a misleading "offline" before we've ever
    /// tested. Tooltip carries the offline reason for power users.
    @ViewBuilder
    private var statusDot: some View {
        switch health.status {
        case .unknown:
            EmptyView()
        case .checking:
            Circle()
                .fill(Color.yellow)
                .frame(width: 8, height: 8)
                .help(String(localized: "settings.hosts.status.checking", defaultValue: "Checking…"))
        case .online:
            Circle()
                .fill(Color.green)
                .frame(width: 8, height: 8)
                .help(String(localized: "settings.hosts.status.online", defaultValue: "Reachable"))
        case .offline(let reason):
            Circle()
                .fill(Color.red)
                .frame(width: 8, height: 8)
                .help(reason)
        }
    }
}

private struct AddHostSheet: View {
    let initial: HerdrHost?
    let onSave: (HerdrHost, Bool) -> Void
    let onCancel: () -> Void

    @State private var displayName: String
    @State private var sshCommand: String
    @State private var sessionName: String
    @State private var autoInstall: Bool
    @State private var probeResult: ProbeResult = .idle
    @State private var parseError: String?

    // Advanced override fields. Empty / false means "use parser /
    // sensible default". Non-empty / true means the user typed a
    // specific value that wins over both the parser and cmux defaults.
    @State private var overrideSshExecutable: String
    @State private var overrideRemoteBinaryPath: String
    @State private var overrideSkipDefaultOptions: Bool
    @State private var showAdvanced: Bool

    enum ProbeResult: Equatable {
        case idle
        case probing
        case success(version: String)
        case failure(reason: String)
    }

    init(
        initial: HerdrHost? = nil,
        onSave: @escaping (HerdrHost, Bool) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.initial = initial
        self.onSave = onSave
        self.onCancel = onCancel
        _displayName = State(initialValue: initial?.displayName ?? "")
        _sessionName = State(initialValue: initial?.sessionName ?? HerdrHost.defaultLocalSessionName())
        _sshCommand = State(initialValue: AddHostSheet.renderCommand(initial?.transport))
        // Default the install checkbox on for fresh remote hosts; off
        // when editing (the binary is presumably already deployed).
        _autoInstall = State(initialValue: initial == nil)

        // Pull existing override values from the initial host so the
        // Advanced fields show what's actually persisted (and we can
        // detect a non-default state to auto-expand the disclosure).
        var sshExe = ""
        var remoteBin = ""
        var skipDefault = false
        if case .sshStdio(_, _, let skip, let exe, let bin) = initial?.transport {
            sshExe = exe ?? ""
            remoteBin = bin ?? ""
            skipDefault = skip
        }
        _overrideSshExecutable = State(initialValue: sshExe)
        _overrideRemoteBinaryPath = State(initialValue: remoteBin)
        _overrideSkipDefaultOptions = State(initialValue: skipDefault)

        // Auto-expand the Advanced disclosure when editing a host that
        // has any non-default override, so the user immediately sees
        // why the saved values look the way they do. New hosts default
        // to collapsed.
        let nonDefault = !sshExe.isEmpty
            || !remoteBin.isEmpty
            || skipDefault
            || (initial != nil && initial?.sessionName != HerdrHost.defaultLocalSessionName())
        _showAdvanced = State(initialValue: nonDefault)
    }

    /// Reverse the parser's normalized fields back to a single-line ssh
    /// command for display when editing. We don't preserve the user's
    /// exact original spelling (quoting choices, flag order in the rare
    /// `-pPORT` glued form), but the resulting command parses back to the
    /// same fields, so a round-trip Save+Edit is a no-op for the model.
    static func renderCommand(_ transport: HerdrHost.Transport?) -> String {
        guard let transport else { return "" }
        guard case .sshStdio(let target, let extraArgs, _, let sshExe, _) = transport else {
            return ""
        }
        var parts: [String] = []
        if let exe = sshExe, !exe.isEmpty {
            parts.append(shellQuote(exe))
        } else {
            parts.append("ssh")
        }
        for arg in extraArgs { parts.append(shellQuote(arg)) }
        parts.append(shellQuote(target))
        return parts.joined(separator: " ")
    }

    /// Single-quote any token that contains shell metacharacters or
    /// spaces. Escapes embedded single quotes by closing the quote,
    /// emitting a backslash-quote, and reopening — the standard POSIX
    /// idiom (`'it'\''s'`).
    private static func shellQuote(_ s: String) -> String {
        if s.isEmpty { return "''" }
        let safe = CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789@%+=:,./-_")
        if s.unicodeScalars.allSatisfy({ safe.contains($0) }) {
            return s
        }
        let escaped = s.replacingOccurrences(of: "'", with: "'\\''")
        return "'\(escaped)'"
    }

    private var isLocalhostEdit: Bool { initial?.isLocalhost ?? false }

    var body: some View {
        if isLocalhostEdit {
            localhostEditBody
        } else {
            sshAddBody
        }
    }

    /// Localhost editing is rare and only needs rename/session-tweak.
    /// Keep it as a small two-field sheet so power users can still
    /// retarget the local agent if they want.
    @ViewBuilder
    private var localhostEditBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(String(localized: "settings.hosts.edit", defaultValue: "Edit computer"))
                .font(.headline)
            Form {
                TextField(
                    String(localized: "settings.hosts.name", defaultValue: "Name"),
                    text: $displayName
                )
                TextField(
                    String(localized: "settings.hosts.session", defaultValue: "Session name"),
                    text: $sessionName
                )
            }
            HStack {
                Spacer()
                Button(String(localized: "settings.hosts.cancel", defaultValue: "Cancel"), action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(String(localized: "settings.hosts.save", defaultValue: "Save")) { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(displayName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(minWidth: 360)
    }

    /// SSH add/edit: simple path is just paste + Save. Power users
    /// expand the Advanced disclosure to override display name, session
    /// namespace, install behavior, and cmux's auto-injected SSH
    /// defaults. The simple path covers ~95% of cases without the user
    /// having to know any of that exists.
    @ViewBuilder
    private var sshAddBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(initial == nil
                 ? String(localized: "settings.hosts.addRemote", defaultValue: "Add a computer")
                 : String(localized: "settings.hosts.editRemote", defaultValue: "Edit computer"))
                .font(.headline)

            Text(String(
                localized: "settings.hosts.sshCommand.label",
                defaultValue: "Paste your ssh command"
            ))
            .font(.caption)
            .foregroundStyle(.secondary)

            TextEditor(text: $sshCommand)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 80, maxHeight: 160)
                .overlay(RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.secondary.opacity(0.3), lineWidth: 1))
                .onChange(of: sshCommand) { _, _ in parseError = nil; probeResult = .idle }

            Text(String(
                localized: "settings.hosts.sshCommand.hintShort",
                defaultValue: "e.g.  ssh user@host -i ~/.ssh/id_ed25519"
            ))
            .font(.caption2)
            .foregroundStyle(.secondary)

            if let parseError {
                Text(parseError).font(.caption).foregroundStyle(.red)
            }

            if let preview = parsedPreview() {
                parsedPreviewRow(preview)
            }

            DisclosureGroup(
                isExpanded: $showAdvanced,
                content: { advancedSection },
                label: {
                    Text(String(
                        localized: "settings.hosts.advanced",
                        defaultValue: "Advanced"
                    ))
                    .font(.caption)
                }
            )
            .padding(.top, 4)

            HStack {
                Spacer()
                Button(String(localized: "settings.hosts.cancel", defaultValue: "Cancel"), action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(String(localized: "settings.hosts.save", defaultValue: "Save")) { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(sshCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(minWidth: 440)
    }

    /// Power-user fields. Empty text/false toggle means "use the
    /// parser's value or cmux's sensible default." A non-empty/true
    /// override wins over both. Keep this collapsed by default; the
    /// init() auto-expands it when editing a host that already has
    /// non-default values so the user immediately sees them.
    @ViewBuilder
    private var advancedSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Form {
                TextField(
                    String(localized: "settings.hosts.name", defaultValue: "Name"),
                    text: $displayName,
                    prompt: Text(parsedPreview()?.target
                        ?? String(localized: "settings.hosts.namePlaceholder", defaultValue: "auto from target"))
                )
                TextField(
                    String(localized: "settings.hosts.session", defaultValue: "Session name"),
                    text: $sessionName
                )
                if !Self.sessionNameIsValid(sessionName) {
                    Text(String(
                        localized: "settings.hosts.sessionInvalid",
                        defaultValue: "Session name must use only letters, digits, dashes, underscores, dots."
                    ))
                    .font(.caption)
                    .foregroundColor(.red)
                }
                Toggle(String(
                    localized: "settings.hosts.autoInstall",
                    defaultValue: "Install cmux agent on save"
                ), isOn: $autoInstall)
                Toggle(String(
                    localized: "settings.hosts.skipDefaultOptions",
                    defaultValue: "Don't inject cmux SSH defaults (ControlMaster, keepalives)"
                ), isOn: $overrideSkipDefaultOptions)
                TextField(
                    String(
                        localized: "settings.hosts.sshExecutable",
                        defaultValue: "Custom ssh executable"
                    ),
                    text: $overrideSshExecutable,
                    prompt: Text("/usr/bin/ssh")
                )
                TextField(
                    String(
                        localized: "settings.hosts.remoteBinaryPath",
                        defaultValue: "Custom cmux agent path on remote"
                    ),
                    text: $overrideRemoteBinaryPath,
                    prompt: Text("herdr-cmux  (uses remote $PATH)")
                )
            }

            HStack {
                Button(String(
                    localized: "settings.hosts.testConnection",
                    defaultValue: "Test connection"
                )) {
                    runProbe()
                }
                .disabled(sshCommand.trimmingCharacters(in: .whitespaces).isEmpty
                          || probeResult == .probing)
                probeResultRow
                Spacer()
            }
        }
    }

    @ViewBuilder
    private var probeResultRow: some View {
        switch probeResult {
        case .idle:
            EmptyView()
        case .probing:
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini).scaleEffect(0.7)
                Text(String(
                    localized: "settings.hosts.probing",
                    defaultValue: "Probing remote…"
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        case .success(let version):
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text(String(
                    localized: "settings.hosts.probeOk",
                    defaultValue: "Found \(version)"
                ))
                .font(.caption)
            }
        case .failure(let reason):
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            }
        }
    }

    private func parsedPreview() -> SSHCommandParser.Parsed? {
        let trimmed = sshCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return try? SSHCommandParser.parse(trimmed)
    }

    @ViewBuilder
    private func parsedPreviewRow(_ p: SSHCommandParser.Parsed) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text(String(
                    localized: "settings.hosts.parsedTarget",
                    defaultValue: "Target: "
                )) + Text(p.target).bold()
            }
            .font(.caption)

            if p.skipDefaultOptions {
                Text(String(
                    localized: "settings.hosts.parsedSshpass",
                    defaultValue: "Detected sshpass — interactive auth defaults will be used."
                ))
                .font(.caption2)
                .foregroundStyle(.orange)
            }
            if !p.extraArgs.isEmpty {
                Text("args: " + p.extraArgs.joined(separator: " "))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
    }

    /// Build a transient HerdrHost from the current sshCommand for use
    /// by the probe button. Sets `parseError` and returns nil on parse
    /// failure so the caller can short-circuit.
    private func buildHostForProbe() -> HerdrHost? {
        let trimmed = sshCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            parseError = "Empty command"
            return nil
        }
        do {
            let parsed = try SSHCommandParser.parse(trimmed)
            parseError = nil
            return HerdrHost(
                id: UUID(),
                displayName: displayName.isEmpty ? parsed.target : displayName,
                transport: .sshStdio(
                    target: parsed.target,
                    extraArgs: parsed.extraArgs,
                    skipDefaultOptions: parsed.skipDefaultOptions,
                    sshExecutable: parsed.sshExecutable,
                    remoteBinaryPath: parsed.remoteBinaryPath
                ),
                sessionName: sessionName.isEmpty ? HerdrHost.defaultLocalSessionName() : sessionName,
                addedAt: Date()
            )
        } catch {
            parseError = error.localizedDescription
            return nil
        }
    }

    private func runProbe() {
        guard let probeHost = buildHostForProbe() else {
            probeResult = .failure(reason: parseError ?? "Invalid SSH command")
            return
        }
        probeResult = .probing
        let reportId = initial?.id ?? probeHost.id
        HostHealthStore.shared.reportChecking(hostId: reportId)
        Task.detached {
            guard let invocation = SSHCommandBuilder.build(
                for: probeHost,
                remoteCommand: ["~/.local/bin/herdr-cmux --version || which herdr-cmux || echo 'NOT FOUND'"]
            ) else {
                await MainActor.run { probeResult = .failure(reason: "Builder rejected host") }
                return
            }
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: invocation.executable)
            proc.arguments = invocation.args
            let pipe = Pipe()
            proc.standardOutput = pipe
            proc.standardError = Pipe()
            do {
                try proc.run()
                proc.waitUntilExit()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let out = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                await MainActor.run {
                    // Mirror probe outcomes into the shared HostHealthStore
                    // so the row dot and the inline probe row never
                    // disagree. Use the *initial* host id when editing —
                    // probeHost is a transient throwaway with a fresh UUID.
                    let reportId = initial?.id ?? probeHost.id
                    if proc.terminationStatus == 0 && out.hasPrefix("herdr ") {
                        probeResult = .success(version: out)
                        HostHealthStore.shared.reportOnline(hostId: reportId)
                    } else if out.contains("NOT FOUND") || out.isEmpty {
                        let reason = String(
                            localized: "settings.hosts.probeMissing",
                            defaultValue: "cmux agent isn't installed on the remote yet. Toggle Install on save."
                        )
                        probeResult = .failure(reason: reason)
                        HostHealthStore.shared.reportOffline(hostId: reportId, reason: reason)
                    } else {
                        probeResult = .failure(reason: out)
                        HostHealthStore.shared.reportOffline(hostId: reportId, reason: out)
                    }
                }
            } catch {
                await MainActor.run {
                    let reason = String(describing: error)
                    probeResult = .failure(reason: reason)
                    let reportId = initial?.id ?? probeHost.id
                    HostHealthStore.shared.reportOffline(hostId: reportId, reason: reason)
                }
            }
        }
    }

    /// Localhost edit only requires a non-empty display name. Remote
    /// add only requires a non-empty paste box (display name and
    /// session name fall back to derived defaults if left empty).
    private var canSave: Bool {
        if isLocalhostEdit {
            guard !displayName.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
            return Self.sessionNameIsValid(sessionName)
        }
        guard !sshCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        return Self.sessionNameIsValid(sessionName)
    }

    /// Session names show up as a directory under `~/.config/herdr/sessions`
    /// and as a literal token in remote shell snippets that auto-spawn the
    /// daemon, so non-ASCII / shell-special chars break setup. Empty is
    /// allowed because `save()` falls back to the cmux default.
    static func sessionNameIsValid(_ s: String) -> Bool {
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return true }
        let allowed = CharacterSet(charactersIn:
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")
        return trimmed.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    private func save() {
        let transport: HerdrHost.Transport
        let derivedDisplayName: String
        let derivedSessionName: String
        if isLocalhostEdit {
            transport = .localUDS
            derivedDisplayName = displayName.trimmingCharacters(in: .whitespaces)
            // Empty session falls back to the cmux default. Saving an
            // empty session name was previously possible because canSave
            // only checked displayName, leading to a host that couldn't
            // ever connect.
            let trimmedSession = sessionName.trimmingCharacters(in: .whitespaces)
            derivedSessionName = trimmedSession.isEmpty
                ? HerdrHost.defaultLocalSessionName()
                : trimmedSession
        } else {
            do {
                let parsed = try SSHCommandParser.parse(
                    sshCommand.trimmingCharacters(in: .whitespacesAndNewlines)
                )
                // Power-user overrides: empty fields fall back to the
                // parser; non-empty wins over both parser and defaults.
                let trimmedExe = overrideSshExecutable.trimmingCharacters(in: .whitespaces)
                let trimmedBin = overrideRemoteBinaryPath.trimmingCharacters(in: .whitespaces)
                let resolvedExe = trimmedExe.isEmpty ? parsed.sshExecutable : trimmedExe
                let resolvedBin = trimmedBin.isEmpty ? parsed.remoteBinaryPath : trimmedBin
                let resolvedSkip = parsed.skipDefaultOptions || overrideSkipDefaultOptions
                transport = .sshStdio(
                    target: parsed.target,
                    extraArgs: parsed.extraArgs,
                    skipDefaultOptions: resolvedSkip,
                    sshExecutable: resolvedExe,
                    remoteBinaryPath: resolvedBin
                )
                let trimmedName = displayName.trimmingCharacters(in: .whitespaces)
                derivedDisplayName = trimmedName.isEmpty ? parsed.target : trimmedName
                let trimmedSession = sessionName.trimmingCharacters(in: .whitespaces)
                derivedSessionName = trimmedSession.isEmpty
                    ? HerdrHost.defaultLocalSessionName()
                    : trimmedSession
            } catch {
                parseError = error.localizedDescription
                return
            }
        }
        let host = HerdrHost(
            id: initial?.id ?? UUID(),
            displayName: derivedDisplayName,
            transport: transport,
            sessionName: derivedSessionName,
            addedAt: initial?.addedAt ?? Date()
        )
        let install = autoInstall && !isLocalhostEdit
        onSave(host, install)
    }
}

/// Standalone window host for the Add Computer flow so menu actions
/// can drop the user straight into the paste-ssh-command dialog
/// without first navigating to Settings → Computers. Mirrors the
/// sheet experience used inside the Settings page; same AddHostSheet
/// view, same save/install path.
@MainActor
enum AddComputerWindow {
    private static var window: NSWindow?

    static func show() {
        if let existing = window {
            existing.makeKeyAndOrderFront(nil)
            return
        }
        let sheet = AddHostSheet(
            onSave: { newHost, install in
                HostRegistry.shared.add(newHost)
                if install {
                    HerdrRemoteInstaller.installOnHost(newHost)
                }
                close()
            },
            onCancel: close
        )
        let hosting = NSHostingController(rootView: sheet)
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 380),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        w.contentViewController = hosting
        w.title = String(localized: "menu.workspaces.addComputer", defaultValue: "Add a computer…")
        // Without an explicit minSize the user can shrink past the
        // sheet's intrinsic SwiftUI minWidth and clip Save/Cancel.
        w.minSize = NSSize(width: 440, height: 320)
        w.center()
        w.isReleasedWhenClosed = false
        // Closing via the red traffic light should reset our singleton
        // so a subsequent show() rebuilds a fresh window.
        let observer = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: w,
            queue: .main
        ) { _ in
            window = nil
        }
        // Park the observer on the window itself so it deallocates with it.
        objc_setAssociatedObject(w, &windowCloseObserverKey, observer, .OBJC_ASSOCIATION_RETAIN)
        window = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private static func close() {
        window?.close()
        window = nil
    }
}

private var windowCloseObserverKey: UInt8 = 0

/// Minimal sheet for adding a non-pinned local-UDS host pointing at a
/// custom herdr session name. Used when the user has run
/// `herdr-cmux session start project-a` outside cmux and wants
/// cmux's sidebar to attach to that session as a separate
/// computer-row, alongside the pinned localhost (which always points
/// at the cmux-default session).
struct AddLocalSessionSheet: View {
    let onSave: (_ sessionName: String, _ displayName: String) -> Void
    let onCancel: () -> Void

    @ObservedObject private var discovery = HerdrSessionDiscovery.shared
    @State private var sessionName: String = ""
    @State private var displayName: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(String(
                localized: "settings.hosts.localSession.title",
                defaultValue: "Add local herdr session"
            ))
            .font(.headline)

            if !discovery.sessions.isEmpty {
                Text(String(
                    localized: "settings.hosts.localSession.discovered",
                    defaultValue: "Detected sessions"
                ))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                ForEach(discovery.sessions) { session in
                    Button {
                        sessionName = session.name
                        if displayName.isEmpty {
                            displayName = session.name
                        }
                    } label: {
                        HStack {
                            Image(systemName: session.isRunning ? "circle.fill" : "circle")
                                .foregroundStyle(session.isRunning ? .green : .secondary)
                            Text(session.name)
                            Spacer()
                            Text(session.socket)
                                .font(.caption.monospaced())
                                .foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                Divider()
            }

            Form {
                TextField(
                    String(localized: "settings.hosts.localSession.sessionName",
                           defaultValue: "Session name"),
                    text: $sessionName
                )
                TextField(
                    String(localized: "settings.hosts.localSession.displayName",
                           defaultValue: "Display name (optional)"),
                    text: $displayName
                )
            }

            HStack {
                Button(String(
                    localized: "settings.hosts.localSession.refresh",
                    defaultValue: "Refresh"
                )) {
                    discovery.refresh()
                }
                Spacer()
                Button(String(
                    localized: "common.cancel",
                    defaultValue: "Cancel"
                ), action: onCancel)
                .keyboardShortcut(.cancelAction)
                Button(String(
                    localized: "common.add",
                    defaultValue: "Add"
                )) {
                    let trimmed = sessionName.trimmingCharacters(in: .whitespaces)
                    guard !trimmed.isEmpty else { return }
                    onSave(trimmed, displayName.trimmingCharacters(in: .whitespaces))
                }
                .keyboardShortcut(.defaultAction)
                .disabled(sessionName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(minWidth: 480)
        .onAppear { discovery.refresh() }
    }
}
