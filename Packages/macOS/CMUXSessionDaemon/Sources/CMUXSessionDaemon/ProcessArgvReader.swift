import Darwin
import Foundation

/// Reads argv for a given pid via `sysctl(KERN_PROCARGS2)`. Used by the zmx
/// detector to discover whether a panel's PTY child (or its descendants) is
/// running `zmx attach <name>`.
public enum ProcessArgvReader {
    public static func argv(forPid pid: pid_t) -> [String]? {
        var size: Int = 0
        var name: [Int32] = [CTL_KERN, KERN_ARGMAX]
        if sysctl(&name, 2, nil, &size, nil, 0) != 0 { return nil }
        var argMax: Int32 = 0
        size = MemoryLayout<Int32>.size
        if sysctl(&name, 2, &argMax, &size, nil, 0) != 0 { return nil }

        var procargs = [Int32](repeating: 0, count: 3)
        procargs[0] = CTL_KERN
        procargs[1] = KERN_PROCARGS2
        procargs[2] = pid
        var bufferSize = Int(argMax)
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        let result = buffer.withUnsafeMutableBufferPointer { ptr -> Int32 in
            sysctl(&procargs, 3, ptr.baseAddress, &bufferSize, nil, 0)
        }
        guard result == 0, bufferSize > MemoryLayout<Int32>.size else { return nil }

        // Layout: [argc: Int32][exec_path: cstring][padding][argv0..argvN][env...]
        var cursor = 0
        let argcRaw = buffer.withUnsafeBufferPointer { ptr -> Int32 in
            ptr.baseAddress!.withMemoryRebound(to: Int32.self, capacity: 1) { $0.pointee }
        }
        cursor += MemoryLayout<Int32>.size
        let argc = Int(argcRaw)
        guard argc > 0 else { return nil }

        // Skip exec_path (null-terminated)
        while cursor < bufferSize, buffer[cursor] != 0 { cursor += 1 }
        // Skip null padding
        while cursor < bufferSize, buffer[cursor] == 0 { cursor += 1 }

        var args: [String] = []
        args.reserveCapacity(argc)
        var current = [UInt8]()
        while cursor < bufferSize, args.count < argc {
            let byte = buffer[cursor]
            cursor += 1
            if byte == 0 {
                if let str = String(bytes: current, encoding: .utf8) {
                    args.append(str)
                }
                current.removeAll(keepingCapacity: true)
            } else {
                current.append(byte)
            }
        }
        return args.isEmpty ? nil : args
    }
}
