import SwiftUI

/// Overlay rendered on a panel whose tracked daemon session exited
/// unexpectedly (process crash, non-zero exit). Provides Restart + Close
/// actions so the user doesn't need to leave the panel to recover.
///
/// The host renders this view conditionally — it doesn't subscribe to any
/// store on its own.
struct SessionExitBannerView: View {
    let cmd: String
    let exitCode: Int
    let onRestart: () -> Void
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.callout)

            VStack(alignment: .leading, spacing: 1) {
                Text(String(
                    localized: "panel.exitBanner.title",
                    defaultValue: "Process exited (\(exitCode))"
                ))
                .font(.callout.weight(.semibold))
                if !cmd.isEmpty {
                    Text(cmd)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            Button(action: onRestart) {
                Text(String(
                    localized: "panel.exitBanner.restart",
                    defaultValue: "Restart"
                ))
            }
            .keyboardShortcut(.defaultAction)
            .accessibilityIdentifier("SessionExitBannerRestart")

            Button(action: onClose) {
                Text(String(
                    localized: "panel.exitBanner.close",
                    defaultValue: "Close"
                ))
            }
            .accessibilityIdentifier("SessionExitBannerClose")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 6))
        .padding(8)
    }
}
