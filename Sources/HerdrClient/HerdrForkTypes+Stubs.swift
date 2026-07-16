import Foundation
import CmuxTerminal

// ponytail: fork bridge for HerdrClient - fork-only ExternalIoBinding shim
extension TerminalSurface {
    public struct ExternalIoBinding {
        public var writeCb: Any?
        public var userdata: UnsafeMutableRawPointer?
        public init(writeCb: Any?, userdata: UnsafeMutableRawPointer?) {
            self.writeCb = writeCb
            self.userdata = userdata
        }
    }
}
