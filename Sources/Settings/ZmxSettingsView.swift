import CMUXZmx
import SwiftUI

/// User-facing surface for the zmx integration. Shows the discovered binary
/// path (or an install hint), exposes an enable toggle, and surfaces a
/// reconcile button. Wiring into the broader Settings tree is deferred —
/// this file just owns the view so the eventual hookup is a one-liner.
struct ZmxSettingsView: View {
    @AppStorage(ZmxSettings.enabledKey) private var integrationEnabled = ZmxSettings.defaultEnabled

    @State private var detection: Detection = .unknown
    @State private var reconcileMessage: String?

    var body: some View {
        SettingsSectionHeader(
            title: String(localized: "settings.section.zmx", defaultValue: "zmx Persistence")
        )
        .settingsSearchAnchor(SettingsSearchIndex.sectionID(for: .zmx))

        SettingsCard {
            SettingsCardRow(
                configurationReview: .settingsOnly,
                String(
                    localized: "settings.zmx.enable",
                    defaultValue: "Track zmx attach sessions"
                ),
                subtitle: enableSubtitle,
                searchAnchorID: "zmx.enable"
            ) {
                Toggle("", isOn: $integrationEnabled)
                    .labelsHidden()
                    .controlSize(.small)
                    .accessibilityIdentifier("SettingsZmxEnableToggle")
                    .accessibilityLabel(
                        String(localized: "settings.zmx.enable", defaultValue: "Track zmx attach sessions")
                    )
            }

            SettingsCardDivider()

            SettingsCardRow(
                configurationReview: .settingsOnly,
                String(
                    localized: "settings.zmx.detection",
                    defaultValue: "zmx binary"
                ),
                subtitle: detectionSubtitle,
                searchAnchorID: "zmx.detection"
            ) {
                EmptyView()
            }

            if integrationEnabled {
                SettingsCardDivider()
                SettingsCardRow(
                    configurationReview: .settingsOnly,
                    String(
                        localized: "settings.zmx.reconcile",
                        defaultValue: "Reconcile bindings"
                    ),
                    subtitle: reconcileMessage ?? String(
                        localized: "settings.zmx.reconcile.subtitle",
                        defaultValue: "Refresh state of every zmx-backed panel."
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
        .task { detection = await Detection.detect() }
    }

    private var enableSubtitle: String {
        if integrationEnabled {
            return String(
                localized: "settings.zmx.enable.on",
                defaultValue: "cmux observes any panel running `zmx attach <name>` and remembers the session for restart."
            )
        }
        return String(
            localized: "settings.zmx.enable.off",
            defaultValue: "Disable to skip every zmx scan; existing bindings on disk are preserved."
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
            return String(
                localized: "settings.zmx.detection.missing",
                defaultValue: "Not installed. Install with `brew install zmx` or visit github.com/neurosnap/zmx."
            )
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

    private func runReconcile() {
        Task {
            let lost = await ZmxCommandHooks.reconcile()
            reconcileMessage = lost.isEmpty
                ? String(
                    localized: "settings.zmx.reconcile.clean",
                    defaultValue: "All bindings still match a live zmx session."
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

        static func detect() async -> Detection {
            await Task.detached(priority: .utility) {
                guard let url = ZmxLocator.resolveBinary(),
                      ZmxLocator.isExecutable(url) else {
                    return Detection.missing
                }
                let version = ZmxLocator.version(at: url)
                return Detection.found(path: url.path, version: version)
            }.value
        }
    }
}

enum ZmxSettings {
    static let enabledKey = "zmx.integration.enabled"
    static let defaultEnabled = true
}
