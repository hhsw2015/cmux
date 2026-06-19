import Foundation

/// On-disk schema for cmux's "project" — a saved layout + the daemon
/// sessions each panel was attached to. Phase 4 reads/writes this; Phase
/// 6 layers per-branch overlays. Lives in the package so the cmux app
/// and any helper tooling share the canonical types.
public struct ProjectManifest: Codable, Sendable, Equatable {
    public var name: String
    public var version: Int
    public var rootDirectory: String?
    public var createdAt: Date
    public var updatedAt: Date
    public var layouts: [String: PanelLayoutTree]   // key = branch name; "" for default

    public init(
        name: String,
        version: Int = 1,
        rootDirectory: String? = nil,
        createdAt: Date = .init(),
        updatedAt: Date = .init(),
        layouts: [String: PanelLayoutTree] = [:]
    ) {
        self.name = name
        self.version = version
        self.rootDirectory = rootDirectory
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.layouts = layouts
    }

    public static let defaultBranchKey = ""
}

/// Recursive layout tree: leaves carry panel descriptors, splits carry
/// direction + ratio + children. Mirrors bonsplit's structure but stays
/// engine-agnostic so non-cmux readers can interpret a manifest.
public indirect enum PanelLayoutTree: Codable, Sendable, Equatable {
    case panel(PanelDescriptor)
    case split(direction: SplitDirection, ratio: Double, children: [PanelLayoutTree])

    public enum SplitDirection: String, Codable, Sendable {
        case horizontal   // left | right
        case vertical     // top  / bottom
    }

    public var leaves: [PanelDescriptor] {
        switch self {
        case .panel(let descriptor):
            return [descriptor]
        case .split(_, _, let children):
            return children.flatMap { $0.leaves }
        }
    }
}

public struct PanelDescriptor: Codable, Sendable, Equatable {
    public var sessionName: String
    public var cmd: String
    public var dir: String
    public var capturedCwd: String?
    public var capturedEnv: [String: String]?
    public var keepAlive: Bool

    public init(
        sessionName: String,
        cmd: String,
        dir: String,
        capturedCwd: String? = nil,
        capturedEnv: [String: String]? = nil,
        keepAlive: Bool = true
    ) {
        self.sessionName = sessionName
        self.cmd = cmd
        self.dir = dir
        self.capturedCwd = capturedCwd
        self.capturedEnv = capturedEnv
        self.keepAlive = keepAlive
    }
}
