import SwiftUI
import Foundation
import AppKit
import Bonsplit
import CMUXSessionDaemon

/// View for rendering a terminal panel
struct TerminalPanelView: View {
    @ObservedObject var panel: TerminalPanel
    @ObservedObject var exitTracker: SessionExitTracker = .shared
    @AppStorage(NotificationPaneRingSettings.enabledKey)
    private var notificationPaneRingEnabled = NotificationPaneRingSettings.defaultEnabled
    let paneId: PaneID
    let isFocused: Bool
    let isVisibleInUI: Bool
    let portalPriority: Int
    let isSplit: Bool
    let appearance: PanelAppearance
    let hasUnreadNotification: Bool
    let onFocus: () -> Void
    let onTriggerFlash: () -> Void

    private var exitEntry: SessionExitTracker.ExitEntry? {
        guard let session = panel.zmxSessionName, !session.isEmpty else { return nil }
        return exitTracker.exitedSessions[session]
    }

    var body: some View {
        // Layering contract: terminal find UI is mounted in GhosttySurfaceScrollView (AppKit portal layer)
        // via `searchState`. Rendering `SurfaceSearchOverlay` in this SwiftUI container can hide it.
        GhosttyTerminalView(
            terminalSurface: panel.surface,
            paneId: paneId,
            isActive: isFocused,
            isVisibleInUI: isVisibleInUI,
            portalZPriority: portalPriority,
            showsInactiveOverlay: isSplit && !isFocused,
            showsUnreadNotificationRing: hasUnreadNotification && notificationPaneRingEnabled,
            inactiveOverlayColor: appearance.unfocusedOverlayNSColor,
            inactiveOverlayOpacity: appearance.unfocusedOverlayOpacity,
            searchState: panel.searchState,
            reattachToken: panel.viewReattachToken,
            onFocus: { _ in onFocus() },
            onTriggerFlash: onTriggerFlash
        )
        // Keep the NSViewRepresentable identity stable across bonsplit structural updates.
        // This prevents transient teardown/recreate that can momentarily detach the hosted terminal view.
        .id(panel.id)
        .background(Color.clear)
        .overlay(alignment: .topTrailing) {
            VStack(alignment: .trailing, spacing: 4) {
                if let session = panel.zmxSessionName, !session.isEmpty {
                    ZmxPanelBadge(sessionName: session)
                        .allowsHitTesting(false)
                }
                if panel.herdrPaneExited {
                    HerdrPaneExitedBadge()
                        .allowsHitTesting(false)
                }
            }
            .padding(.top, 4)
            .padding(.trailing, 6)
        }
        .overlay(alignment: .bottom) {
            if let exit = exitEntry {
                SessionExitBannerView(
                    cmd: exit.sessionName,
                    exitCode: exit.exitCode,
                    onRestart: { restartExitedSession(exit) },
                    onClose: { exitTracker.clear(sessionName: exit.sessionName) }
                )
            }
        }
    }

    private func restartExitedSession(_ exit: SessionExitTracker.ExitEntry) {
        exitTracker.clear(sessionName: exit.sessionName)
        // Type the attach command into the panel's PTY. The user can also
        // edit it before pressing return; the trailing newline executes
        // it immediately when no edits are made.
        let engine = SessionDaemonResolver.shared.selectedKind() ?? .tsm
        let binary = engine == .tsm ? "tsm" : "zmx"
        _ = panel.surface.sendText("\(binary) attach \(exit.sessionName)\n")
    }
}

/// Pill shown in a herdr-backed panel's top-right corner once the
/// daemon broadcasts `pane.exited` for that pane. The pane itself
/// stays alive (tmux semantics: scrollback is intact, the user can
/// dismiss it explicitly via Close Pane); the badge tells the user
/// the underlying process is gone.
struct HerdrPaneExitedBadge: View {
    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "xmark.octagon.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.red)
            Text(
                String(
                    localized: "panel.herdr.exited",
                    defaultValue: "Process exited"
                )
            )
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .foregroundStyle(.primary)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(.thinMaterial, in: Capsule())
        .accessibilityLabel(
            String(
                localized: "panel.herdr.exited.a11y",
                defaultValue: "Herdr-backed pane process has exited"
            )
        )
    }
}

/// Lightweight ⚡ pill rendered in a terminal panel's top-right corner when
/// the panel's foreground process is a tracked `zmx attach`. Read-only —
/// reattach / kill flows live in the command palette.
struct ZmxPanelBadge: View {
    let sessionName: String

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "bolt.horizontal.circle.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.yellow)
            Text(sessionName)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(.thinMaterial, in: Capsule())
        .accessibilityLabel(
            String(
                localized: "panel.zmx.badge",
                defaultValue: "Persistent zmx session: \(sessionName)"
            )
        )
    }
}

/// Shared appearance settings for panels
struct PanelAppearance {
    let backgroundColor: NSColor
    let foregroundColor: NSColor
    let dividerColor: Color
    let unfocusedOverlayNSColor: NSColor
    let unfocusedOverlayOpacity: Double
    let usesClearContentBackground: Bool

    var contentBackgroundColor: NSColor {
        usesClearContentBackground ? .clear : backgroundColor
    }

    var drawsContentBackground: Bool {
        !usesClearContentBackground
    }

    static func fromConfig(_ config: GhosttyConfig) -> PanelAppearance {
        fromConfig(config, usesTransparentWindow: cmuxShouldUseTransparentBackgroundWindow())
    }

    static func fromConfig(_ config: GhosttyConfig, usesTransparentWindow: Bool) -> PanelAppearance {
        PanelAppearance(
            backgroundColor: GhosttyBackgroundTheme.color(
                backgroundColor: config.backgroundColor,
                opacity: config.backgroundOpacity
            ),
            foregroundColor: config.foregroundColor,
            dividerColor: Color(nsColor: config.resolvedSplitDividerColor),
            unfocusedOverlayNSColor: config.unfocusedSplitOverlayFill,
            unfocusedOverlayOpacity: config.unfocusedSplitOverlayOpacity,
            usesClearContentBackground: shouldUseClearContentBackground(
                opacity: config.backgroundOpacity,
                usesGhosttyGlassStyle: config.backgroundBlur.isMacOSGlassStyle,
                usesTransparentWindow: usesTransparentWindow
            )
        )
    }

    static func shouldUseClearContentBackground(
        opacity: Double,
        usesGhosttyGlassStyle: Bool,
        usesTransparentWindow: Bool
    ) -> Bool {
        usesTransparentWindow || usesGhosttyGlassStyle || opacity < 0.999
    }
}
