import AppKit
import CmuxTerminal

@MainActor
final class TerminalSurfacePaneHostingAdapter: NSView, TerminalSurfacePaneHosting {
    private let underlying: GhosttySurfaceScrollView

    init(underlying: GhosttySurfaceScrollView) {
        self.underlying = underlying
        super.init(frame: underlying.frame)
        addSubview(underlying)
        underlying.frame = bounds
        underlying.autoresizingMask = [.width, .height]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func attachSurface(_ surface: CmuxTerminal.TerminalSurface) { underlying.attachSurface(surface as! TerminalSurface) }
    func cancelFocusRequest() { underlying.cancelFocusRequest() }
    func setVisibleInUI(_ visible: Bool) { underlying.setVisibleInUI(visible) }
    func setActive(_ active: Bool) { underlying.setActive(active) }
    func syncKeyStateIndicator(text: String?) { underlying.syncKeyStateIndicator(text: text) }
    func terminalSurfaceDidReceiveExplicitInput() {}
    func setMobileViewportBorder(size: CGSize?, drawRight: Bool, drawBottom: Bool) {
        underlying.setMobileViewportBorder(size: size, drawRight: drawRight, drawBottom: drawBottom)
    }
}
