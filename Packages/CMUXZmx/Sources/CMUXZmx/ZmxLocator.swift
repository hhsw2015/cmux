import Foundation

public enum ZmxLocator {
    public static var candidatePaths: [String] {
        var paths: [String] = [
            "/opt/homebrew/bin/zmx",
            "/usr/local/bin/zmx",
            "/usr/bin/zmx",
        ]
        let home = NSHomeDirectory()
        paths.append("\(home)/.local/bin/zmx")
        paths.append("\(home)/.cargo/bin/zmx")
        return paths
    }

    public static func resolveBinary(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        useCandidatePaths: Bool = true
    ) -> URL? {
        if let pathEnv = environment["PATH"] {
            for dir in pathEnv.split(separator: ":") {
                let candidate = URL(fileURLWithPath: String(dir)).appendingPathComponent("zmx")
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
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else {
            return false
        }
        return FileManager.default.isExecutableFile(atPath: url.path)
    }

    public static func version(at url: URL, timeout: TimeInterval = 2.0) -> String? {
        let process = Process()
        process.executableURL = url
        process.arguments = ["--version"]
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
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
