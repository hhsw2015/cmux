import Foundation

/// Pure decision logic that turns a `(binding, environment)` snapshot into a
/// concrete `RestoreAction`. No I/O, no side effects: makes the decision table
/// testable in isolation. Callers handle the actual launch + index update.
public enum ZmxRestorePlanner {
    public enum RestoreAction: Sendable, Equatable {
        /// Re-run the original argv to attach. Caller should refresh the binding's
        /// `attachState` to `.attached` and `lastSeenAt` after success.
        case attach(argv: [String], workingDirectory: String)

        /// Skip auto-attach; panel launches a normal shell. Binding is kept so
        /// the UI can offer a "reattach" affordance.
        case offerReattach(binding: RestorableZmxBinding)

        /// Drop the binding from the index and launch a normal shell. The
        /// session is gone and there's nothing meaningful to remember.
        case clearBinding(reason: ClearReason)

        /// Skip — no binding existed, normal shell launch.
        case noop
    }

    public enum ClearReason: String, Sendable {
        case zmxBinaryMissing
        case zmxBinaryNotExecutable
        case sessionNotAlive
    }

    public struct Environment: Sendable {
        public let zmxBinaryAvailable: Bool
        public let zmxBinaryExecutable: Bool
        public let aliveSessions: Set<String>

        public init(zmxBinaryAvailable: Bool, zmxBinaryExecutable: Bool, aliveSessions: Set<String>) {
            self.zmxBinaryAvailable = zmxBinaryAvailable
            self.zmxBinaryExecutable = zmxBinaryExecutable
            self.aliveSessions = aliveSessions
        }
    }

    public static func plan(binding: RestorableZmxBinding?, environment: Environment) -> RestoreAction {
        guard let binding else { return .noop }

        guard environment.zmxBinaryAvailable else {
            return .clearBinding(reason: .zmxBinaryMissing)
        }
        guard environment.zmxBinaryExecutable else {
            return .clearBinding(reason: .zmxBinaryNotExecutable)
        }

        let alive = environment.aliveSessions.contains(binding.zmxSessionName)
        guard alive else {
            return .clearBinding(reason: .sessionNotAlive)
        }

        switch binding.attachState {
        case .attached:
            return .attach(
                argv: binding.originalArgv,
                workingDirectory: binding.workingDirectory
            )
        case .detached:
            return .offerReattach(binding: binding)
        case .lost:
            // Binding was previously marked lost but session is alive again —
            // treat as detached so the user re-confirms.
            return .offerReattach(binding: binding)
        }
    }
}
