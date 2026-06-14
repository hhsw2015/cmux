import AppKit
import Foundation

@_silgen_name("CGSDefaultConnectionForThread")
private func cmuxCGSDefaultConnectionForThread() -> UnsafeMutableRawPointer?

@_silgen_name("CGSSetWindowBackgroundBlurRadius")
@discardableResult
private func cmuxCGSSetWindowBackgroundBlurRadius(
    _ connection: UnsafeMutableRawPointer?,
    _ windowNumber: UInt,
    _ radius: Int32
) -> Int32

func cmuxSetCompositorBackgroundBlur(on window: NSWindow, radius: Int) {
    let clampedRadius = Int32(max(0, min(radius, Int(Int32.max))))
    _ = cmuxCGSSetWindowBackgroundBlurRadius(
        cmuxCGSDefaultConnectionForThread(),
        UInt(window.windowNumber),
        clampedRadius
    )
}

func cmuxResetCompositorBackgroundBlur(on window: NSWindow) {
    cmuxSetCompositorBackgroundBlur(on: window, radius: 0)
}

func cmuxTransparentWindowBaseColor() -> NSColor {
    NSColor.white.withAlphaComponent(0.001)
}
