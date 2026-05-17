import Foundation

/// Disk-backed CRUD for ProjectManifests. Pure I/O; cmux callers handle
/// the actual workspace materialization.
public struct ProjectManifestStore: Sendable {
    public let directory: URL

    public init(directory: URL = ProjectManifestStore.defaultDirectory()) {
        self.directory = directory
    }

    public static func defaultDirectory() -> URL {
        let fm = FileManager.default
        let support = (try? fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let dir = support
            .appendingPathComponent("cmux", isDirectory: true)
            .appendingPathComponent("projects", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    public func list() throws -> [String] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: directory.path) else { return [] }
        return try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .map { $0.deletingPathExtension().lastPathComponent }
            .sorted()
    }

    public func load(name: String) throws -> ProjectManifest {
        let url = self.url(for: name)
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(ProjectManifest.self, from: data)
    }

    public func save(_ manifest: ProjectManifest) throws {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        var copy = manifest
        copy.updatedAt = .init()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(copy)
        try data.write(to: url(for: copy.name), options: .atomic)
    }

    public func delete(name: String) throws {
        let url = self.url(for: name)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    public func url(for name: String) -> URL {
        let safe = Self.sanitize(name)
        return directory.appendingPathComponent("\(safe).json")
    }

    /// Filesystem-safe project name. Strips path separators so a malicious
    /// or accidental "/" doesn't escape the project directory.
    public static func sanitize(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let scalars = trimmed.unicodeScalars.map { scalar -> Character in
            if scalar == "/" || scalar == "\\" || scalar == ":" || scalar == "\0" {
                return "-"
            }
            return Character(scalar)
        }
        let cleaned = String(scalars)
        return cleaned.isEmpty ? "untitled" : cleaned
    }
}
