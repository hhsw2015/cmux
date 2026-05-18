import Darwin
import Foundation

/// System-wide scan for live `zmx attach` invocations. Returns one entry per
/// pid whose argv parses as a tracked zmx attach. Cheap (single sysctl table)
/// and self-contained: callers can periodically diff this against the cached
/// `ZmxBindingIndex` to drive reconciliation.
public enum ZmxSystemScanner {
    public struct LiveAttach: Sendable, Equatable {
        public let pid: pid_t
        public let parentPid: pid_t
        public let sessionName: String
        public let argv: [String]
    }

    public static func scan() -> [LiveAttach] {
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        if sysctl(&name, 3, nil, &size, nil, 0) != 0 { return [] }
        // Add headroom: process table can grow between the size query and the
        // data fetch. Round up to next 16-process slack.
        let stride = MemoryLayout<kinfo_proc>.stride
        let count = (size / stride) + 16
        size = count * stride
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: count)
        let res = procs.withUnsafeMutableBufferPointer { ptr -> Int32 in
            sysctl(&name, 3, ptr.baseAddress, &size, nil, 0)
        }
        guard res == 0 else { return [] }
        let actualCount = min(size / stride, count)

        var live: [LiveAttach] = []
        for i in 0..<actualCount {
            let pid = procs[i].kp_proc.p_pid
            guard pid > 0 else { continue }
            // Quick reject: process name must contain "zmx".
            let pcommBytes = withUnsafeBytes(of: procs[i].kp_proc.p_comm) { Array($0) }
            let pcomm = String(bytes: pcommBytes.prefix(while: { $0 != 0 }), encoding: .utf8) ?? ""
            guard pcomm == "zmx" || pcomm.hasSuffix("/zmx") else { continue }

            guard let argv = ProcessArgvReader.argv(forPid: pid),
                  let parsed = ZmxArgvParser.parse(argv) else { continue }

            live.append(LiveAttach(
                pid: pid,
                parentPid: procs[i].kp_eproc.e_ppid,
                sessionName: parsed.sessionName,
                argv: argv
            ))
        }
        return live
    }
}
