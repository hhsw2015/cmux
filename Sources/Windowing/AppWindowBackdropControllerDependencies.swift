import AppKit
import CmuxAppKitSupportUI
import CmuxWorkspaceWindow

@MainActor
final class AppWindowBackdropControllerDependencies: WindowBackdropControllerDependencies {
    let glassEffect: any WindowGlassEffectManaging

    init(glassEffect: any WindowGlassEffectManaging) {
        self.glassEffect = glassEffect
    }

    func resetCompositorBackgroundBlur(windowNumber: Int) {
        WindowBackgroundComposition.blurController.resetBackgroundBlur(windowNumber: windowNumber)
    }

    func applyGhosttyCompositorBlurIfNeeded(to window: NSWindow) {
        // ponytail: applyWindowBlurIfNeeded was extracted upstream and replaced
        // by direct compositor calls; backdrop controller no longer drives this.
        _ = window
    }
}
