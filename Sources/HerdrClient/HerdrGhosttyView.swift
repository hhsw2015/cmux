import AppKit
import GhosttyKit
import QuartzCore

/// Minimal NSView that hosts a Ghostty surface in **manual** I/O mode
/// for the herdr integration debug window. Differs from
/// GhosttyTerminalView in three deliberate ways:
///
/// 1. `io_mode = GHOSTTY_SURFACE_IO_MANUAL` — Ghostty does NOT spawn a
///    shell. We feed PTY bytes via `ghostty_surface_process_output()`
///    and Ghostty calls our `io_write_cb` whenever the user's input
///    needs to flow back into a PTY (which we forward to
///    HerdrDisplayClient).
/// 2. No env vars / cwd / command — none of the cmux-side identity
///    plumbing needed because no shell is spawned here.
/// 3. No hookup to bonsplit / TabManager / SidebarState — this is a
///    standalone debug view inside a NSWindowController.
///
/// This is intentionally a thin slice that demonstrates the
/// embedder-owned-IO path end-to-end. Productionizing it (focus
/// management, mouse routing, paste, IME, scrollback, theme, fonts
/// matching the rest of cmux, etc.) lands when this code merges into
/// the real panel layer.
final class HerdrGhosttyView: NSView {
    private(set) var surface: ghostty_surface_t?
    private var callbackContext: UnsafeMutableRawPointer?
    private weak var inputForwardTarget: HerdrSurfaceController?

    override var wantsUpdateLayer: Bool { true }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func makeBackingLayer() -> CALayer {
        let layer = CAMetalLayer()
        layer.pixelFormat = .bgra8Unorm
        layer.framebufferOnly = false
        layer.isOpaque = true
        return layer
    }

    /// Build the Ghostty surface and bind it to a controller. Must be
    /// called after the view is in a window so layer + scale factor are
    /// real. Idempotent: a second call replaces the previous surface.
    /// Starts the controller's own AsyncStream pump.
    func attachController(_ controller: HerdrSurfaceController) {
        attachControllerCore(controller, startPump: true)
    }

    /// Same as attachController but skips the controller's pump start.
    /// Use when the caller owns the only AsyncStream consumer and tees
    /// chunks into the surface manually via
    /// `ghostty_surface_process_output(view.surface, ...)`. Avoids
    /// fighting over the single-consumer AsyncStream<Data>.
    func attachControllerWithoutPump(_ controller: HerdrSurfaceController) {
        attachControllerCore(controller, startPump: false)
    }

    private func attachControllerCore(
        _ controller: HerdrSurfaceController,
        startPump: Bool
    ) {
        teardownSurfaceIfAny()
        guard let app = GhosttyApp.shared.app else {
            NSLog("[HerdrGhosttyView] GhosttyApp.shared.app nil — cannot create surface")
            return
        }
        var config = ghostty_surface_config_new()
        config.platform_tag = GHOSTTY_PLATFORM_MACOS
        config.platform = ghostty_platform_u(macos: ghostty_platform_macos_s(
            nsview: Unmanaged.passUnretained(self).toOpaque()
        ))
        let scale = window?.backingScaleFactor ?? 2.0
        config.scale_factor = scale
        config.context = GHOSTTY_SURFACE_CONTEXT_WINDOW
        config.io_mode = GHOSTTY_SURFACE_IO_MANUAL

        // Hold strong ref to the controller via callback context. Ghostty
        // calls io_write_cb with this userdata pointer when the user
        // types something while focused on the surface; we forward to
        // the controller, which forwards to HerdrDisplayClient.
        let ctxBox = HerdrIoCallbackContext(controller: controller)
        let ctxRaw = Unmanaged.passRetained(ctxBox).toOpaque()
        config.io_write_userdata = ctxRaw
        config.io_write_cb = herdrIoWriteCallback
        callbackContext = ctxRaw
        inputForwardTarget = controller

        guard let surface = ghostty_surface_new(app, &config) else {
            NSLog("[HerdrGhosttyView] ghostty_surface_new returned nil")
            Unmanaged<HerdrIoCallbackContext>.fromOpaque(ctxRaw).release()
            callbackContext = nil
            return
        }
        self.surface = surface
        if startPump {
            controller.attach(surface: surface)
        } else {
            controller.bindSurfaceWithoutPump(surface)
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // If the view was added to a window AFTER attachController, we
        // would also need to re-create the surface to pick up the right
        // scale factor. The debug window adds the view first then
        // connects, so this branch is currently unreachable.
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if let surface, newSize.width > 0, newSize.height > 0 {
            ghostty_surface_set_size(
                surface,
                UInt32(newSize.width),
                UInt32(newSize.height)
            )
        }
    }

    deinit {
        teardownSurfaceIfAny()
    }

    private func teardownSurfaceIfAny() {
        if let surface {
            ghostty_surface_free(surface)
        }
        surface = nil
        if let ctxRaw = callbackContext {
            Unmanaged<HerdrIoCallbackContext>.fromOpaque(ctxRaw).release()
        }
        callbackContext = nil
        inputForwardTarget = nil
    }
}

/// Bridges the C `io_write_cb` callback signature back into Swift.
/// Released by HerdrGhosttyView when the surface is torn down.
private final class HerdrIoCallbackContext {
    weak var controller: HerdrSurfaceController?
    init(controller: HerdrSurfaceController) {
        self.controller = controller
    }
}

/// C-callable function pointer compatible with `ghostty_io_write_cb`.
/// Ghostty calls this on the main thread whenever the surface has
/// keystroke / paste output to deliver "into the PTY" — we redirect
/// that into the herdr display client.
private let herdrIoWriteCallback: ghostty_io_write_cb = { (ud, ptr, len) in
    guard let ud, let ptr, len > 0 else { return }
    let ctx = Unmanaged<HerdrIoCallbackContext>.fromOpaque(ud).takeUnretainedValue()
    let buffer = UnsafeBufferPointer(
        start: UnsafeRawPointer(ptr).assumingMemoryBound(to: UInt8.self),
        count: Int(len)
    )
    let data = Data(buffer)
    Task { @MainActor in
        ctx.controller?.sendInput(data)
    }
}
