import AppKit
import SwiftUI

/// AppKit-backed hover probe for the auto-hide top tab bar.
///
/// Why not a plain `Color.clear.onHover` overlay in SwiftUI: `.onHover`
/// requires the view to be hit-testable, but a hit-testable overlay sitting
/// on top of Bonsplit's tab strip swallows every close/select click on the
/// revealed tab bar. We need "receives pointer enter/exit events but does
/// NOT intercept clicks". `NSTrackingArea` on an `NSView` gives us exactly
/// that: mouseEntered/mouseExited fire regardless of `hitTest(_:)`, and we
/// return nil from `hitTest(_:)` so mouse-down / mouse-up sail through to
/// the tab strip below.
struct TopTabsHoverProbe: NSViewRepresentable {
    var revealedHeight: CGFloat
    var armedHeight: CGFloat
    var isRevealed: Bool
    var onHoverChange: (Bool) -> Void

    func makeNSView(context: Context) -> HoverProbeView {
        let view = HoverProbeView()
        view.onHoverChange = onHoverChange
        return view
    }

    func updateNSView(_ nsView: HoverProbeView, context: Context) {
        nsView.onHoverChange = onHoverChange
    }

    final class HoverProbeView: NSView {
        var onHoverChange: ((Bool) -> Void)?
        private var trackingArea: NSTrackingArea?

        override func hitTest(_ point: NSPoint) -> NSView? {
            // Never win hit-tests — clicks pass through to the tab strip.
            nil
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let existing = trackingArea {
                removeTrackingArea(existing)
            }
            let options: NSTrackingArea.Options = [
                .mouseEnteredAndExited,
                .activeInKeyWindow,
                .inVisibleRect,
            ]
            let area = NSTrackingArea(rect: .zero, options: options, owner: self, userInfo: nil)
            addTrackingArea(area)
            trackingArea = area
        }

        override func mouseEntered(with event: NSEvent) {
            onHoverChange?(true)
        }

        override func mouseExited(with event: NSEvent) {
            onHoverChange?(false)
        }
    }
}
