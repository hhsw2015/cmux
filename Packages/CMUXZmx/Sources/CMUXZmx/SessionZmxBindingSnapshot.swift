import Foundation

/// Codable subset of `RestorableZmxBinding` suitable for embedding in
/// cmux's `SessionPanelSnapshot.terminal` payload. Decoupled from the
/// full binding model so the saved-state file format doesn't drift when
/// `RestorableZmxBinding` grows new runtime-only fields.
public struct SessionZmxBindingSnapshot: Codable, Sendable, Equatable {
    public let zmxSessionName: String
    public let originalArgv: [String]
    public let workingDirectory: String
    public let attachState: RestorableZmxBinding.AttachState
    public let lastSeenAt: Date

    public init(
        zmxSessionName: String,
        originalArgv: [String],
        workingDirectory: String,
        attachState: RestorableZmxBinding.AttachState,
        lastSeenAt: Date
    ) {
        self.zmxSessionName = zmxSessionName
        self.originalArgv = originalArgv
        self.workingDirectory = workingDirectory
        self.attachState = attachState
        self.lastSeenAt = lastSeenAt
    }

    /// Build a snapshot from a runtime binding for serialization into the
    /// session-state JSON.
    public init(binding: RestorableZmxBinding) {
        self.zmxSessionName = binding.zmxSessionName
        self.originalArgv = binding.originalArgv
        self.workingDirectory = binding.workingDirectory
        self.attachState = binding.attachState
        self.lastSeenAt = binding.lastSeenAt
    }

    /// Restore a runtime binding from a serialized snapshot. The caller must
    /// supply the workspaceId/panelId since those are owned by the panel
    /// snapshot wrapper, not this nested record. `zmxBinaryPath` is filled
    /// from the current `ZmxLocator` resolution at restore time so an
    /// upgraded binary is picked up automatically.
    public func materialize(
        workspaceId: UUID,
        panelId: UUID,
        zmxBinaryPath: String
    ) -> RestorableZmxBinding {
        RestorableZmxBinding(
            workspaceId: workspaceId,
            panelId: panelId,
            zmxSessionName: zmxSessionName,
            zmxBinaryPath: zmxBinaryPath,
            socketPath: nil,
            originalArgv: originalArgv,
            workingDirectory: workingDirectory,
            attachState: attachState,
            attachedAt: lastSeenAt,
            lastSeenAt: lastSeenAt
        )
    }
}
