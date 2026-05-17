import CMUXZmx
import SwiftUI

/// User-facing surface for the session-persistence integration. Picks an
/// engine (none / zmx / tsm), shows detection state for the chosen engine,
/// exposes a reconcile button. tsm is recommended because it covers the
/// full feature set (keep-alive + projects + branch worktrees + agent
/// merge); zmx covers only the lightweight subset.
struct ZmxSettingsView: View {
    @AppStorage(SessionDaemonResolver.engineDefaultsKey) private var engineRaw = "tsm"
    @AppStorage(ZmxSettings.enabledKey) private var integrationEnabled = ZmxSettings.defaultEnabled
    @AppStorage(ZmxSettings.defaultKeepAliveKey) private var defaultKeepAlive = ZmxSettings.defaultKeepAliveDefault

    @State private var detection: Detection = .unknown
    @State private var reconcileMessage: String?

    var body: some View {
        SettingsSectionHeader(
            title: String(localized: "settings.section.zmx", defaultValue: "Session Persistence")
        )
        .settingsSearchAnchor(SettingsSearchIndex.sectionID(for: .zmx))

        SettingsCard {
            SettingsCardRow(
                configurationReview: .settingsOnly,
                String(
                    localized: "settings.zmx.engine",
                    defaultValue: "Engine"
                ),
                subtitle: engineSubtitle,
                searchAnchorID: "zmx.engine"
            ) {
                Picker("", selection: $engineRaw) {
                    Text(String(localized: "settings.zmx.engine.none", defaultValue: "None")).tag("none")
                    Text("tsm (recommended)").tag("tsm")
                    Text("zmx").tag("zmx")
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .controlSize(.small)
                .accessibilityIdentifier("SettingsSessionPersistenceEnginePicker")
            }

            SettingsCardDivider()

            SettingsCardRow(
                configurationReview: .settingsOnly,
                String(
                    localized: "settings.zmx.enable",
                    defaultValue: "Track session attachments"
                ),
                subtitle: enableSubtitle,
                searchAnchorID: "zmx.enable"
            ) {
                Toggle("", isOn: $integrationEnabled)
                    .labelsHidden()
                    .controlSize(.small)
                    .accessibilityIdentifier("SettingsZmxEnableToggle")
                    .disabled(engineRaw == "none")
            }

            SettingsCardDivider()

            SettingsCardRow(
                configurationReview: .settingsOnly,
                String(
                    localized: "settings.zmx.defaultKeepAlive",
                    defaultValue: "Keep new terminals alive by default"
                ),
                subtitle: String(
                    localized: "settings.zmx.defaultKeepAlive.subtitle",
                    defaultValue: "New panels start with keep-alive on. Individual panels can override from their context menu."
                ),
                searchAnchorID: "zmx.defaultKeepAlive"
            ) {
                Toggle("", isOn: $defaultKeepAlive)
                    .labelsHidden()
                    .controlSize(.small)
                    .accessibilityIdentifier("SettingsZmxDefaultKeepAliveToggle")
                    .disabled(!integrationEnabled || engineRaw == "none")
            }

            SettingsCardDivider()

            SettingsCardRow(
                configurationReview: .settingsOnly,
                String(
                    localized: "settings.zmx.detection",
                    defaultValue: "Engine binary"
                ),
                subtitle: detectionSubtitle,
                searchAnchorID: "zmx.detection"
            ) {
                EmptyView()
            }

            if integrationEnabled, engineRaw != "none" {
                SettingsCardDivider()
                SettingsCardRow(
                    configurationReview: .settingsOnly,
                    String(
                        localized: "settings.zmx.reconcile",
                        defaultValue: "Reconcile bindings"
                    ),
                    subtitle: reconcileMessage ?? String(
                        localized: "settings.zmx.reconcile.subtitle",
                        defaultValue: "Refresh state of every persistent panel."
                    ),
                    searchAnchorID: "zmx.reconcile"
                ) {
                    Button(action: runReconcile) {
                        Text(String(
                            localized: "settings.zmx.reconcile.button",
                            defaultValue: "Reconcile"
                        ))
                    }
                    .controlSize(.small)
                    .disabled(detection == .missing)
                }
            }
        }
        .task(id: engineRaw) { detection = await Detection.detect(engine: engineRaw) }
    }

    private var engineSubtitle: String {
        switch engineRaw {
        case "tsm":
            return String(
                localized: "settings.zmx.engine.tsm",
                defaultValue: "tsm: persistent sessions, projects, git worktrees, agent state. Recommended."
            )
        case "zmx":
            return String(
                localized: "settings.zmx.engine.zmx",
                defaultValue: "zmx: lightweight session persistence only. No projects or worktrees."
            )
        default:
            return String(
                localized: "settings.zmx.engine.noneDescription",
                defaultValue: "cmux runs without any persistent-session daemon. Closing a panel kills its process."
            )
        }
    }

    private var enableSubtitle: String {
        if engineRaw == "none" {
            return String(
                localized: "settings.zmx.enable.engineNone",
                defaultValue: "Pick an engine first."
            )
        }
        if integrationEnabled {
            return String(
                localized: "settings.zmx.enable.on",
                defaultValue: "cmux watches any panel running an attach command and remembers the session for restart."
            )
        }
        return String(
            localized: "settings.zmx.enable.off",
            defaultValue: "Disable to skip every scan; existing bindings on disk are preserved."
        )
    }

    private var detectionSubtitle: String {
        switch detection {
        case .unknown:
            return String(
                localized: "settings.zmx.detection.checking",
                defaultValue: "Checking…"
            )
        case .missing:
            return missingHelpText(for: engineRaw)
        case .found(let path, let version):
            if let version, !version.isEmpty {
                return String(
                    localized: "settings.zmx.detection.foundWithVersion",
                    defaultValue: "Detected at \(path) (\(version))."
                )
            }
            return String(
                localized: "settings.zmx.detection.found",
                defaultValue: "Detected at \(path)."
            )
        }
    }

    private func missingHelpText(for engine: String) -> String {
        switch engine {
        case "tsm":
            return String(
                localized: "settings.zmx.detection.tsmMissing",
                defaultValue: "tsm not installed. See github.com/adibhanna/tsm for install instructions."
            )
        case "zmx":
            return String(
                localized: "settings.zmx.detection.zmxMissing",
                defaultValue: "zmx not installed. Install with `brew install zmx` or see github.com/neurosnap/zmx."
            )
        default:
            return String(
                localized: "settings.zmx.detection.noneSelected",
                defaultValue: "No engine selected."
            )
        }
    }

    private func runReconcile() {
        Task {
            let lost = await ZmxCommandHooks.reconcile()
            reconcileMessage = lost.isEmpty
                ? String(
                    localized: "settings.zmx.reconcile.clean",
                    defaultValue: "All bindings still match a live session."
                )
                : String(
                    localized: "settings.zmx.reconcile.flipped",
                    defaultValue: "\(lost.count) binding(s) marked lost."
                )
        }
    }

    enum Detection: Equatable {
        case unknown
        case missing
        case found(path: String, version: String?)

        static func detect(engine: String) async -> Detection {
            await Task.detached(priority: .utility) {
                switch engine {
                case "tsm":
                    guard let url = TsmLocator.resolveBinary(),
                          TsmLocator.isExecutable(url) else { return Detection.missing }
                    return Detection.found(path: url.path, version: TsmLocator.version(at: url))
                case "zmx":
                    guard let url = ZmxLocator.resolveBinary(),
                          ZmxLocator.isExecutable(url) else { return Detection.missing }
                    return Detection.found(path: url.path, version: ZmxLocator.version(at: url))
                default:
                    return Detection.missing
                }
            }.value
        }
    }
}

enum ZmxSettings {
    static let enabledKey = "zmx.integration.enabled"
    static let defaultEnabled = true

    /// When true, every newly-created terminal panel gets keepAlive=on
    /// by default. Off by default — users opt panels in individually
    /// via the right-click menu.
    static let defaultKeepAliveKey = "zmx.integration.defaultKeepAlive"
    static let defaultKeepAliveDefault = false
}
