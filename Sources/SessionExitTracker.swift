import CMUXSessionDaemon
import Combine
import Foundation

/// Listens to a `PollingDaemonEventSource` and republishes session-exit
/// events keyed by panel id. SwiftUI views observe `lastExit` to render
/// `SessionExitBannerView` without subscribing to the AsyncStream
/// directly.
@MainActor
final class SessionExitTracker: ObservableObject {
    static let shared = SessionExitTracker()

    /// Most recent exit event per *session name*. Banners look up by the
    /// session their panel is bound to.
    @Published private(set) var exitedSessions: [String: ExitEntry] = [:]

    struct ExitEntry: Equatable {
        let sessionName: String
        let exitCode: Int
        let observedAt: Date
    }

    private var task: Task<Void, Never>?

    func start() {
        guard task == nil else { return }
        guard SessionPersistenceFeatureFlags.effective(.exitBanner) else { return }
        guard let backend = SessionDaemonResolver.shared.activeBackend() else { return }
        let source = PollingDaemonEventSource(backend: backend, interval: 3.0)
        task = Task { [weak self] in
            let stream = await source.events()
            for await event in stream {
                guard !Task.isCancelled else { break }
                if case .sessionExited(let name, let code) = event {
                    await MainActor.run {
                        self?.recordExit(sessionName: name, exitCode: code)
                    }
                }
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    func clear(sessionName: String) {
        exitedSessions.removeValue(forKey: sessionName)
    }

    private func recordExit(sessionName: String, exitCode: Int) {
        exitedSessions[sessionName] = ExitEntry(
            sessionName: sessionName,
            exitCode: exitCode,
            observedAt: .init()
        )
    }
}
