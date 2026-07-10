import CmuxWorkspaces
import Foundation

/// Surface navigation and sidebar status helpers extracted from `Workspace.swift`, which sits at its file-length budget.
extension Workspace {
    /// Notification unread lookup for sidebar surface indicators.
    func hasUnreadNotification(panelId: UUID) -> Bool {
        AppDelegate.shared?.notificationStore?.hasUnreadNotification(forTabId: id, surfaceId: panelId) ?? false
    }

    /// Surface-kind mapping used by workspace state snapshots.
    func surfaceKind(for panel: any Panel) -> String {
        switch panel.panelType {
        case .terminal:
            return SurfaceKind.terminal
        case .browser:
            return SurfaceKind.browser
        case .markdown:
            return SurfaceKind.markdown
        case .filePreview:
            return SurfaceKind.filePreview
        case .rightSidebarTool:
            return SurfaceKind.rightSidebarTool
        case .customSidebar:
            return SurfaceKind.customSidebar
        case .agentSession:
            return SurfaceKind.agentSession
        case .project:
            return SurfaceKind.project
        case .extensionBrowser:
            return SurfaceKind.extensionBrowser
        case .cloudVMLoading:
            return SurfaceKind.cloudVMLoading
        }
    }

    /// Select the next surface in the currently focused split pane, or in
    /// workspace Canvas order when Canvas layout is active.
    func selectNextSurface() {
        if layoutMode == .canvas {
            _ = selectAdjacentCanvasTab(offset: 1)
            return
        }
        bonsplitController.selectNextTab()

        if let paneId = bonsplitController.focusedPaneId,
           let tabId = bonsplitController.selectedTab(inPane: paneId)?.id {
            applyTabSelection(tabId: tabId, inPane: paneId)
        }
    }

    /// Select the previous surface in the currently focused split pane, or in
    /// workspace Canvas order when Canvas layout is active.
    func selectPreviousSurface() {
        if layoutMode == .canvas {
            _ = selectAdjacentCanvasTab(offset: -1)
            return
        }
        bonsplitController.selectPreviousTab()

        if let paneId = bonsplitController.focusedPaneId,
           let tabId = bonsplitController.selectedTab(inPane: paneId)?.id {
            applyTabSelection(tabId: tabId, inPane: paneId)
        }
    }

    /// Select a surface by index in the currently focused split pane, or in
    /// workspace Canvas order when Canvas layout is active.
    func selectSurface(at index: Int) {
        if layoutMode == .canvas {
            _ = selectCanvasTab(at: index)
            return
        }
        guard let focusedPaneId = bonsplitController.focusedPaneId else { return }
        let tabs = bonsplitController.tabs(inPane: focusedPaneId)
        guard tabs.indices.contains(index) else { return }
        bonsplitController.selectTab(tabs[index].id)

        if let tabId = bonsplitController.selectedTab(inPane: focusedPaneId)?.id {
            applyTabSelection(tabId: tabId, inPane: focusedPaneId)
        }
    }

    /// Select the last surface in the currently focused split pane, or in
    /// workspace Canvas order when Canvas layout is active.
    func selectLastSurface() {
        if layoutMode == .canvas {
            _ = selectLastCanvasTab()
            return
        }
        guard let focusedPaneId = bonsplitController.focusedPaneId else { return }
        let tabs = bonsplitController.tabs(inPane: focusedPaneId)
        guard let last = tabs.last else { return }
        bonsplitController.selectTab(last.id)

        if let tabId = bonsplitController.selectedTab(inPane: focusedPaneId)?.id {
            applyTabSelection(tabId: tabId, inPane: focusedPaneId)
        }
    }
}
