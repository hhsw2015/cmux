import Foundation

public struct ZmxClient: Sendable {
    public let binaryPath: URL
    public let processTimeout: TimeInterval

    public init(binaryPath: URL, processTimeout: TimeInterval = 3.0) {
        self.binaryPath = binaryPath
        self.processTimeout = processTimeout
    }

    public func listAlive() throws -> Set<String> {
        let output = try runCapturing(arguments: ["ls", "--short"])
        let names = output
            .split(whereSeparator: { $0 == "\n" || $0 == "\r" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return Set(names)
    }

    public func isAlive(_ sessionName: String) -> Bool {
        guard let alive = try? listAlive() else { return false }
        return alive.contains(sessionName)
    }

    public func kill(_ sessionName: String, force: Bool = false) throws {
        var args = ["kill", sessionName]
        if force { args.append("--force") }
        _ = try runCapturing(arguments: args)
    }

    private func runCapturing(arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = binaryPath
        process.arguments = arguments
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()

        let deadline = Date().addingTimeInterval(processTimeout)
        while process.isRunning {
            if Date() > deadline {
                process.terminate()
                throw ZmxClientError.timeout(arguments: arguments)
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        guard process.terminationStatus == 0 else {
            let errData = (try? stderr.fileHandleForReading.readToEnd()) ?? Data()
            let errText = String(data: errData, encoding: .utf8) ?? ""
            throw ZmxClientError.nonZeroExit(
                status: process.terminationStatus,
                stderr: errText.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        let outData = (try? stdout.fileHandleForReading.readToEnd()) ?? Data()
        return String(data: outData, encoding: .utf8) ?? ""
    }
}

public enum ZmxClientError: Error, Equatable {
    case timeout(arguments: [String])
    case nonZeroExit(status: Int32, stderr: String)
}
