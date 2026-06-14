import CmuxTerminal
import Foundation
import GhosttyKit

public extension TerminalSurface {
    struct ExternalIoBinding {
        public let writeCb: ghostty_io_write_cb
        public let userdata: UnsafeMutableRawPointer?

        public init(
            writeCb: ghostty_io_write_cb,
            userdata: UnsafeMutableRawPointer?
        ) {
            self.writeCb = writeCb
            self.userdata = userdata
        }
    }
}
