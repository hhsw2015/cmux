import Foundation

/// Mirror of `ZmxLocator` for the `tsm` binary.
public enum TsmLocator {
    public static var candidatePaths: [String] {
        var paths: [String] = [
            "/opt/homebrew/bin/tsm",
            "/usr/local/bin/tsm",
            "/usr/bin/tsm",
        ]
        let home = NSHomeDirectory()
        paths.append("\(home)/.local/bin/tsm")
        paths.append("\(home)/.cargo/bin/tsm")
        paths.append("\(home)/go/bin/tsm")
        return paths
    }

    public static func resolveBinary(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        useCandidatePaths: Bool = true
    ) -> URL? {
        if let pathEnv = environment["PATH"] {
            for dir in pathEnv.split(separator: ":") {
                let candidate = URL(fileURLWithPath: String(dir)).appendingPathComponent("tsm")
                if isExecutable(candidate) { return candidate }
            }
        }
        guard useCandidatePaths else { return nil }
        for path in candidatePaths {
            let url = URL(fileURLWithPath: path)
            if isExecutable(url) { return url }
        }
        return nil
    }

    public static func isExecutable(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir),
              !isDir.boolValue else {
            return false
        }
        return FileManager.default.isExecutableFile(atPath: url.path)
    }

    public static func version(at url: URL, timeout: TimeInterval = 2.0) -> String? {
        let process = Process()
        process.executableURL = url
        process.arguments = ["version"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return nil
        }
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning {
            if Date() > deadline {
                process.terminate()
                return nil
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        guard let data = try? pipe.fileHandleForReading.readToEnd(),
              let text = String(data: data, encoding: .utf8) else {
            return nil
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
    }

    /// Default tsm session directory. `$TSM_DIR` overrides it; cmux respects
    /// the same env var so dev installations under custom paths work.
    public static func sessionDirectory(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let custom = environment["TSM_DIR"], !custom.isEmpty {
            return URL(fileURLWithPath: custom).appendingPathComponent("sessions", isDirectory: true)
        }
        let home = environment["HOME"] ?? NSHomeDirectory()
        return URL(fileURLWithPath: home)
            .appendingPathComponent(".local/share/tsm/sessions", isDirectory: true)
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
