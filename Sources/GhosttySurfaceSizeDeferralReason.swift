import AppKit
import Carbon.HIToolbox

// ponytail: fork-only fork-tab-drag size deferral seam, restored after upstream extracts removed it.
enum GhosttySurfaceSizeDeferralReason: String {
    case tabDrag
}

enum GhosttySurfaceSizeRetryPolicy {
    static func shouldScheduleImmediateRetry(deferralReason: GhosttySurfaceSizeDeferralReason) -> Bool {
        switch deferralReason {
        case .tabDrag:
            return false
        }
    }

    static func shouldRunQueuedRetry(after eventType: NSEvent.EventType) -> Bool {
        switch eventType {
        case .leftMouseUp, .rightMouseUp, .otherMouseUp:
            return true
        default:
            return false
        }
    }

    static func shouldRunQueuedRetry(afterKeyDown keyCode: UInt16) -> Bool {
        keyCode == UInt16(kVK_Escape)
    }
}
