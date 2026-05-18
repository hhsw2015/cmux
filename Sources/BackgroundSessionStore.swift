import Combine
import CMUXSessionDaemon
import Foundation

/// Tracks zmx/tsm sessions whose cmux panel was closed but whose daemon
/// process is still alive. Phase 3 surfaces this in the sidebar; Phase 2
/// only needs the storage so keep-alive panels have somewhere to land.
///
/// Lives at the @MainActor scope so SwiftUI views can observe the
/// `@Published sessions` array without bridging.
@MainActor
final class BackgroundSessionStore: ObservableObject {
    static let shared = BackgroundSessionStore()

    @Published private(set) var sessions: [Entry] = []

    struct Entry: Identifiable, Equatable {
        let id: UUID                 // original panelId
        let workspaceId: UUID
        let sessionName: String
        let cmd: String
        let dir: String
        let detachedAt: Date
    }

    func add(_ entry: Entry) {
        sessions.removeAll { $0.id == entry.id }
        sessions.append(entry)
        sessions.sort { $0.detachedAt > $1.detachedAt }
    }

    func remove(panelId: UUID) {
        sessions.removeAll { $0.id == panelId }
    }

    func remove(sessionName: String) {
        sessions.removeAll { $0.sessionName == sessionName }
    }

    func contains(sessionName: String) -> Bool {
        sessions.contains { $0.sessionName == sessionName }
    }
}
