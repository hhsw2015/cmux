import Darwin
import Foundation

/// Walks the descendant process tree of a panel's PTY pid looking for an
/// active `zmx attach/run <name>` invocation. Used by cmux to write/refresh
/// `RestorableZmxBinding` records without hooking into the Ghostty PTY spawn
/// path.
public enum ZmxPanelDetector {
    public struct Detection: Sendable, Equatable {
        public let parsed: ZmxArgvParser.ParsedSession
        public let pid: pid_t
        public let argv: [String]
    }

    /// Returns the *most recent* (deepest) zmx invocation among descendants of `rootPid`.
    /// Returns nil when no descendant is a tracked zmx subcommand.
    public static func detect(rootPid: pid_t, parentByPid: [Int: Int]? = nil) -> Detection? {
        guard rootPid > 0 else { return nil }
        let parents = parentByPid ?? Self.buildParentMap()
        let descendants = Self.descendants(of: Int(rootPid), parents: parents)
        var deepest: Detection?
        var deepestDepth = -1
        for pid in descendants {
            guard let argv = ProcessArgvReader.argv(forPid: pid_t(pid)) else { continue }
            guard let parsed = ZmxArgvParser.parse(argv) else { continue }
            // Prefer the zmx process closer to the leaf so latest reattaches win.
            let d = depth(of: pid, parents: parents, root: Int(rootPid))
            if d > deepestDepth {
                deepestDepth = d
                deepest = Detection(parsed: parsed, pid: pid_t(pid), argv: argv)
            }
        }
        return deepest
    }

    public static func buildParentMap() -> [Int: Int] {
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        if sysctl(&name, 3, nil, &size, nil, 0) != 0 { return [:] }
        let stride = MemoryLayout<kinfo_proc>.stride
        let count = (size / stride) + 16
        size = count * stride
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: count)
        let res = procs.withUnsafeMutableBufferPointer { ptr -> Int32 in
            sysctl(&name, 3, ptr.baseAddress, &size, nil, 0)
        }
        guard res == 0 else { return [:] }
        let actualCount = min(size / stride, count)
        var map: [Int: Int] = [:]
        for i in 0..<actualCount {
            let pid = Int(procs[i].kp_proc.p_pid)
            let ppid = Int(procs[i].kp_eproc.e_ppid)
            if pid > 0 { map[pid] = ppid }
        }
        return map
    }

    private static func descendants(of root: Int, parents: [Int: Int]) -> [Int] {
        // Build child map from parent map.
        var children: [Int: [Int]] = [:]
        for (pid, ppid) in parents {
            children[ppid, default: []].append(pid)
        }
        var result: [Int] = []
        var stack: [Int] = [root]
        while let pid = stack.popLast() {
            if let kids = children[pid] {
                for kid in kids {
                    result.append(kid)
                    stack.append(kid)
                }
            }
        }
        return result
    }

    private static func depth(of pid: Int, parents: [Int: Int], root: Int) -> Int {
        var depth = 0
        var current = pid
        while let parent = parents[current], parent != 0, current != root, depth < 100 {
            depth += 1
            current = parent
            if current == root { break }
        }
        return depth
    }
}
