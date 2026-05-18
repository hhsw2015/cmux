#if DEBUG
import CMUXDebugLog

@inline(__always)
func cmuxDebugLog(_ message: @autoclosure () -> String) {
    CMUXDebugLog.logDebugEvent(message())
}
#else
@inline(__always)
func cmuxDebugLog(_ message: @autoclosure () -> String) {}
#endif
