import Foundation

public struct RestorableZmxBinding: Codable, Sendable, Equatable {
    public let workspaceId: UUID
    public let panelId: UUID
    public let zmxSessionName: String
    public let zmxBinaryPath: String
    public let socketPath: String?
    public let originalArgv: [String]
    public let workingDirectory: String
    public var attachState: AttachState
    public let attachedAt: Date
    public var lastSeenAt: Date

    public enum AttachState: String, Codable, Sendable {
        case attached
        case detached
        case lost
    }

    public init(
        workspaceId: UUID,
        panelId: UUID,
        zmxSessionName: String,
        zmxBinaryPath: String,
        socketPath: String? = nil,
        originalArgv: [String],
        workingDirectory: String,
        attachState: AttachState = .attached,
        attachedAt: Date = .init(),
        lastSeenAt: Date = .init()
    ) {
        self.workspaceId = workspaceId
        self.panelId = panelId
        self.zmxSessionName = zmxSessionName
        self.zmxBinaryPath = zmxBinaryPath
        self.socketPath = socketPath
        self.originalArgv = originalArgv
        self.workingDirectory = workingDirectory
        self.attachState = attachState
        self.attachedAt = attachedAt
        self.lastSeenAt = lastSeenAt
    }
}
