import Foundation

enum TerminalNotificationKind: String, Codable, Hashable, Sendable {
    case user
    case bus
}

extension Notification.Name {
    /// Posted (on whatever queue the publish lands on) every time a new
    /// notification — bus or user — is appended to the store. The
    /// userInfo dict carries the notification id under
    /// `TerminalNotificationStore.appendedNotificationIdKey`. Used by
    /// `notification.wait` to do event-driven blocking instead of polling.
    static let cmuxNotificationAppended = Notification.Name("cmux.notification.appended")
}

struct TerminalNotification: Identifiable, Hashable, Sendable {
    let id: UUID
    let tabId: UUID
    let surfaceId: UUID?
    let panelId: UUID?
    let title: String
    let subtitle: String
    let body: String
    let createdAt: Date
    var isRead: Bool
    var paneFlash: Bool = true
    var scrollPosition: TerminalNotificationScrollPosition?
    var clickAction: TerminalNotificationClickAction?
    var kind: TerminalNotificationKind = .user

    init(
        id: UUID,
        tabId: UUID,
        surfaceId: UUID?,
        panelId: UUID? = nil,
        title: String,
        subtitle: String,
        body: String,
        createdAt: Date,
        isRead: Bool,
        paneFlash: Bool = true,
        scrollPosition: TerminalNotificationScrollPosition? = nil,
        clickAction: TerminalNotificationClickAction? = nil,
        kind: TerminalNotificationKind = .user
    ) {
        self.id = id
        self.tabId = tabId
        self.surfaceId = surfaceId
        self.panelId = panelId
        self.title = title
        self.subtitle = subtitle
        self.body = body
        self.createdAt = createdAt
        self.isRead = isRead
        self.paneFlash = paneFlash
        self.scrollPosition = scrollPosition
        self.clickAction = clickAction
        self.kind = kind
    }

    func matches(tabId targetTabId: UUID, surfaceId targetSurfaceId: UUID?) -> Bool {
        guard tabId == targetTabId else { return false }
        guard let targetSurfaceId else {
            return surfaceId == nil && panelId == nil
        }
        return surfaceId == targetSurfaceId || panelId == targetSurfaceId
    }
}
