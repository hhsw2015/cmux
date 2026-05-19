import SwiftUI

/// Settings page for managing herdr hosts (the machines that run a herdr
/// daemon and persist sessions). Localhost is auto-listed; user can add
/// remote SSH targets.
struct HostsSettingsView: View {
    @ObservedObject private var registry: HostRegistry = .shared
    @State private var showingAdd = false
    @State private var editing: HerdrHost?
    @AppStorage(HerdrNotificationSettings.blockedNotificationsEnabledKey)
    private var blockedNotificationsEnabled: Bool = HerdrNotificationSettings.blockedNotificationsEnabledDefault

    var body: some View {
        SettingsSectionHeader(
            title: String(localized: "settings.section.hosts", defaultValue: "Hosts")
        )
        .settingsSearchAnchor(SettingsSearchIndex.sectionID(for: .hosts))

        SettingsCard {
            ForEach(registry.hosts) { host in
                HostRow(
                    host: host,
                    onEdit: { editing = host },
                    onRemove: host.isLocalhost ? nil : { registry.remove(id: host.id) }
                )
                if host.id != registry.hosts.last?.id {
                    Divider()
                }
            }
        }

        HStack {
            Toggle(String(
                localized: "settings.hosts.notifyBlocked",
                defaultValue: "Notify when remote agent waits for input"
            ), isOn: $blockedNotificationsEnabled)
            Spacer()
            Button {
                showingAdd = true
            } label: {
                Label(
                    String(localized: "settings.hosts.add", defaultValue: "Add host"),
                    systemImage: "plus.circle"
                )
            }
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
    }
}

private struct HostRow: View {
    let host: HerdrHost
    let onEdit: () -> Void
    let onRemove: (() -> Void)?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: host.isLocalhost ? "laptopcomputer" : "server.rack")
                .foregroundStyle(.secondary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(host.displayName)
                    .font(.body)
                Text(transportSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(action: onEdit) {
                Image(systemName: "pencil")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(String(
                localized: "settings.hosts.edit",
                defaultValue: "Edit host"
            ))
            if let onRemove {
                Button(role: .destructive, action: onRemove) {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(String(
                    localized: "settings.hosts.remove",
                    defaultValue: "Remove host"
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
        case .sshStdio(let target):
            return "ssh: \(target) · session: \(host.sessionName)"
        }
    }
}

private struct AddHostSheet: View {
    let initial: HerdrHost?
    let onSave: (HerdrHost, Bool) -> Void
    let onCancel: () -> Void

    @State private var displayName: String
    @State private var sshTarget: String
    @State private var sessionName: String
    @State private var autoInstall: Bool

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
        if case .sshStdio(let t) = initial?.transport {
            _sshTarget = State(initialValue: t)
        } else {
            _sshTarget = State(initialValue: "")
        }
        // Default the install checkbox on for fresh remote hosts; off
        // when editing (the binary is presumably already deployed).
        _autoInstall = State(initialValue: initial == nil)
    }

    private var isLocalhostEdit: Bool { initial?.isLocalhost ?? false }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(initial == nil
                 ? String(localized: "settings.hosts.add", defaultValue: "Add host")
                 : String(localized: "settings.hosts.edit", defaultValue: "Edit host"))
                .font(.headline)

            Form {
                TextField(
                    String(localized: "settings.hosts.name", defaultValue: "Name"),
                    text: $displayName
                )
                if !isLocalhostEdit {
                    TextField(
                        String(localized: "settings.hosts.sshTarget", defaultValue: "SSH target (user@host or alias)"),
                        text: $sshTarget
                    )
                }
                TextField(
                    String(localized: "settings.hosts.session", defaultValue: "Herdr session name"),
                    text: $sessionName
                )
                if !isLocalhostEdit {
                    Toggle(String(
                        localized: "settings.hosts.autoInstall",
                        defaultValue: "Install herdr-cmux on save"
                    ), isOn: $autoInstall)
                }
            }

            HStack {
                Spacer()
                Button(String(localized: "settings.hosts.cancel", defaultValue: "Cancel"), action: onCancel)
                Button(String(localized: "settings.hosts.save", defaultValue: "Save")) {
                    save()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
            }
        }
        .padding(20)
        .frame(minWidth: 380)
    }

    private var canSave: Bool {
        let trimmed = displayName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return false }
        guard !sessionName.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        if !isLocalhostEdit && initial?.transport != .localUDS {
            return !sshTarget.trimmingCharacters(in: .whitespaces).isEmpty
        }
        return true
    }

    private func save() {
        let transport: HerdrHost.Transport
        if isLocalhostEdit {
            transport = .localUDS
        } else {
            transport = .sshStdio(target: sshTarget.trimmingCharacters(in: .whitespaces))
        }
        let host = HerdrHost(
            id: initial?.id ?? UUID(),
            displayName: displayName.trimmingCharacters(in: .whitespaces),
            transport: transport,
            sessionName: sessionName.trimmingCharacters(in: .whitespaces),
            addedAt: initial?.addedAt ?? Date()
        )
        let install = autoInstall && !isLocalhostEdit
        onSave(host, install)
    }
}
