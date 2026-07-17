import Foundation
import GhosttyKit
import CmuxTerminal

// Fork bridge: HerdrClient needs the pre-merge `TerminalSurface.ExternalIoBinding`
// payload type to build its external-io write callback. Upstream removed the
// binding from CmuxTerminal, so declare it here with the real C-callable
// signatures (not `Any?`) — anything less silently breaks every keystroke.
extension TerminalSurface {
    public struct ExternalIoBinding: Sendable {
        public let writeCb: ghostty_io_write_cb
        public let userdata: UnsafeMutableRawPointer
        public init(writeCb: ghostty_io_write_cb, userdata: UnsafeMutableRawPointer) {
            self.writeCb = writeCb
            self.userdata = userdata
        }
    }
}
