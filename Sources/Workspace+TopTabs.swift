import Bonsplit
import CmuxPanes
import CmuxSidebar
import CmuxTerminal
import CmuxWorkspaces
import Foundation

// Fork feature: workspace top-tab bar (multiple parallel bonsplit trees per
// workspace, switched via a `topTabController`-driven top bar). Ported from
// the pre-merge Workspace.swift as a layered extension so upstream's single
// `bonsplitController` stored property and its 200+ existing access sites
// keep working — we swap the property in place when switching layout tabs.
@MainActor
extension Workspace {
    // MARK: - Layout tab lookup

    /// Returns the layout tab (workspace's own top-level tab) that hosts the
    /// given bonsplit controller, or nil if `controller` is the workspace's
    /// top-tab bar controller itself.
    func layoutTab(containing controller: BonsplitController) -> WorkspaceLayoutTab? {
        layoutTabs.first { $0.bonsplitController === controller }
    }

    /// Returns the layout tab whose bonsplit tree contains the given
    /// surface id (a Bonsplit TabID), driving cross-layout surface lookups.
    func layoutTab(containingSurfaceId surfaceId: TabID) -> WorkspaceLayoutTab? {
        layoutTabs.first { $0.surfaceIdToPanelId[surfaceId] != nil }
    }

    /// Returns the layout tab whose bonsplit tree contains the given
    /// panel id.
    func layoutTab(containingPanelId panelId: UUID) -> WorkspaceLayoutTab? {
        layoutTabs.first { layout in
            layout.surfaceIdToPanelId.values.contains(panelId)
        }
    }

    /// All bonsplit controllers across every layout tab. Fork machinery
    /// (herdr layout apply, session persistence) walks this for cross-tree
    /// searches.
    var layoutBonsplitControllers: [BonsplitController] {
        layoutTabs.map(\.bonsplitController)
    }

    /// Look up the layout tab that owns a given pane id, exposed for
    /// herdr inbound code that needs to remember which tab a binding
    /// belongs to.
    func layoutTabId(containingPaneId paneId: PaneID) -> UUID? {
        layoutTabs.first { $0.bonsplitController.allPaneIds.contains(paneId) }?.id
    }

    /// Resolve the BonsplitController that owns a given pane, across all
    /// layout tabs. Returns nil if the pane isn't part of this workspace's
    /// tree family.
    func bonsplitController(containingPaneId paneId: PaneID) -> BonsplitController? {
        layoutBonsplitControllers.first { $0.allPaneIds.contains(paneId) }
    }

    /// Resolve the BonsplitController for a given layout tab id. Used by
    /// herdr inbound LayoutChanged handlers to route mutations into the
    /// SAME layout tab the binding lives in, even when the user has a
    /// different top tab active.
    func bonsplitController(forLayoutTabId layoutTabId: UUID?) -> BonsplitController? {
        guard let layoutTabId else { return nil }
        return layoutTabs.first { $0.id == layoutTabId }?.bonsplitController
    }

    // MARK: - Top-tab navigation (Cmd+Alt+←/→ etc.)

    /// Cmd+Alt+→: cycle to the next layout tab in the workspace's top bar.
    func selectNextTopLevelTab() {
        topTabController.selectNextTab()
    }

    /// Cmd+Alt+←: cycle to the previous layout tab.
    func selectPreviousTopLevelTab() {
        topTabController.selectPreviousTab()
    }

    /// True if `topTabId` is the currently active layout tab.
    func isSelectedTopLevelTab(_ topTabId: TabID) -> Bool {
        selectedLayoutTabId == topTabId.uuid
    }

    // MARK: - Herdr adapters

    /// Herdr stale-workspace detector. Ported from pre-merge fork; today the
    /// authoritative check moved elsewhere (see HerdrAutoReattach), so this
    /// keeps returning false as a workspace-level fallback.
    func isDeadHerdrStub() -> Bool { false }

    /// Force every tab across every layout tab into "may close" state, used
    /// after a herdr disconnect so the user's `⌘W` isn't gated on the last
    /// pane rule while the workspace is being torn down.
    func markAllTabsForceCloseable() {
        for controller in layoutBonsplitControllers {
            for tabId in controller.allTabIds {
                forceCloseTabIds.insert(tabId)
            }
        }
    }

    /// Herdr inbound programmatic split (loose form; older herdr code calls
    /// this with an untyped direction + panel id). Resolves the pane and
    /// delegates to the typed variant.
    func herdrInboundSplit(direction: SplitOrientation, panelId: UUID, source _: String) {
        guard let paneId = paneId(forPanelId: panelId) else { return }
        _ = herdrInboundSplit(paneId: paneId, orientation: direction, initialDividerPosition: 0.5)
    }

    /// Herdr inbound programmatic split. Marks the split as programmatic so
    /// bonsplit doesn't fire an outbound RPC in response, then routes into
    /// the layout tab that owns the pane (falls back to the active one).
    @discardableResult
    func herdrInboundSplit(
        paneId: PaneID,
        orientation: SplitOrientation,
        initialDividerPosition: CGFloat
    ) -> PaneID? {
        isProgrammaticSplit = true
        defer { isProgrammaticSplit = false }
        let controller = bonsplitController(containingPaneId: paneId) ?? bonsplitController
        return controller.splitPane(
            paneId,
            orientation: orientation,
            withTab: nil,
            initialDividerPosition: initialDividerPosition
        )
    }

    // MARK: - New / close / select top tabs

    /// Cmd+T: create a fresh layout tab with an empty split tree, add a
    /// terminal surface in it, and select it. Returns the created panel or
    /// nil if creation failed. Pre-merge fork behavior for "new top tab".
    @discardableResult
    func newTopLevelTerminalTab(focus: Bool = true, initialInput: String? = nil) -> TerminalPanel? {
        let nextTitle = String(
            localized: "workspace.topTab.newTerminal.title",
            defaultValue: "Terminal"
        )
        let previousLayoutId = selectedLayoutTabId
        guard let layout = Self.makeLayoutTab(
            title: nextTitle,
            surfaceConfiguration: bonsplitController.configuration,
            topTabController: topTabController
        ) else { return nil }

        let inheritedDirectory = currentDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        let workingDirectory = inheritedDirectory.isEmpty ? nil : inheritedDirectory
        let welcomeTabIds = layout.bonsplitController.allTabIds
        for welcomeTabId in welcomeTabIds {
            layout.bonsplitController.closeTab(welcomeTabId)
        }
        layoutTabs.append(layout)
        configureLayoutController(layout.bonsplitController)
        _ = selectTopLevelTab(id: layout.id, reassertAppKitFocus: false)

        guard let paneId = layout.bonsplitController.focusedPaneId ?? layout.bonsplitController.allPaneIds.first else {
            removeTopLevelLayoutTab(layout, fallbackLayoutId: previousLayoutId)
            return nil
        }
        guard let panel = newTerminalSurface(
            inPane: paneId,
            focus: focus,
            initialInput: initialInput
        ) else {
            removeTopLevelLayoutTab(layout, fallbackLayoutId: previousLayoutId)
            return nil
        }
        if focus {
            focusPanel(panel.id)
        }
        syncTopLevelTabMetadata(for: layout)
        if HerdrLayoutTabBridge.isDaemonBackedWorkspace(self) {
            HerdrLayoutTabBridge.mirrorNewLayoutTabIfBacked(
                workspace: self,
                layoutTabId: layout.id,
                rootPaneId: paneId
            )
        }
        return panel
    }

    /// Switch the workspace to the given layout tab id. Returns true iff the
    /// id resolved. Reentrant on `isApplyingTopLevelTabSelection` (bonsplit
    /// selection callbacks re-enter through us).
    @discardableResult
    func selectTopLevelTab(id layoutId: UUID, reassertAppKitFocus: Bool = true) -> Bool {
        guard let layout = layoutTabs.first(where: { $0.id == layoutId }) else { return false }
        selectedLayoutTabId = layout.id
        // Swap the workspace's "current" bonsplit in place so existing sites
        // that read `workspace.bonsplitController` see the new tree.
        bonsplitController = layout.bonsplitController
        guard !isApplyingTopLevelTabSelection else { return true }

        isApplyingTopLevelTabSelection = true
        defer { isApplyingTopLevelTabSelection = false }

        let selectedTopTab = topTabController.focusedPaneId
            .flatMap { topTabController.selectedTab(inPane: $0)?.id }
        if selectedTopTab != layout.topTabId {
            topTabController.selectTab(layout.topTabId)
        }
        applySelectedTopLevelTabFocus(reassertAppKitFocus: reassertAppKitFocus)
        return true
    }

    /// Remove a layout tab (and close its mirrored daemon tab if any),
    /// selecting `fallbackLayoutId` (or the first surviving tab) afterward.
    func removeTopLevelLayoutTab(_ layout: WorkspaceLayoutTab, fallbackLayoutId: UUID?) {
        HerdrLayoutTabBridge.closeMirroredLayoutTab(workspace: self, layoutTabId: layout.id)
        layoutTabs.removeAll { $0.id == layout.id }
        forceCloseTopLevelTabIds.insert(layout.topTabId)
        if !topTabController.closeTab(layout.topTabId) {
            forceCloseTopLevelTabIds.remove(layout.topTabId)
        }
        guard selectedLayoutTabId == layout.id || selectedLayoutTabId == nil else { return }
        let fallback = fallbackLayoutId.flatMap { id in
            layoutTabs.first(where: { $0.id == id })?.id
        } ?? layoutTabs.first?.id
        selectedLayoutTabId = fallback
        if let fallback {
            _ = selectTopLevelTab(id: fallback, reassertAppKitFocus: false)
        }
    }

    // MARK: - Factory

    /// Create a fresh WorkspaceLayoutTab: a new top-tab entry in
    /// `topTabController`, backed by a new BonsplitController for its
    /// content. Nil if the top-tab creation failed.
    static func makeLayoutTab(
        title: String,
        surfaceConfiguration: BonsplitConfiguration,
        topTabController: BonsplitController,
        closeExistingTopWelcomeTabs: Bool = false
    ) -> WorkspaceLayoutTab? {
        let topWelcomeTabIds = closeExistingTopWelcomeTabs ? topTabController.allTabIds : []
        guard let topTabId = topTabController.createTab(
            title: title,
            icon: "terminal.fill",
            kind: "workspaceLayout"
        ) else { return nil }
        for welcomeTabId in topWelcomeTabIds {
            topTabController.closeTab(welcomeTabId)
        }
        let layoutController = BonsplitController(configuration: surfaceConfiguration)
        return WorkspaceLayoutTab(topTabId: topTabId, bonsplitController: layoutController)
    }

    // MARK: - Metadata sync (top-bar reflects the layout's selected surface)

    /// Refresh the top-bar tab entry for `layout` to match the currently
    /// selected surface inside it (title, icon, dirty flag, notif badge).
    func syncTopLevelTabMetadata(for layout: WorkspaceLayoutTab) {
        guard let panelId = selectedPanelId(in: layout),
              let panel = panels[panelId] else { return }
        let fallback = panelTitles[panelId] ?? panel.displayTitle
        let title = resolvedPanelTitle(panelId: panelId, fallback: fallback)
        let browser = panel as? BrowserPanel
        let iconImageData: Data?? = {
            if let browser { return .some(browser.faviconPNGData) }
            return .some(nil)
        }()
        topTabController.updateTab(
            layout.topTabId,
            title: title,
            icon: .some(panel.displayIcon),
            iconImageData: iconImageData,
            kind: .some(surfaceKind(for: panel)),
            hasCustomTitle: panelCustomTitles[panelId] != nil,
            isDirty: panel.isDirty,
            showsNotificationBadge: hasVisibleNotificationIndicator(panelId: panelId),
            isLoading: browser?.isLoading ?? false
        )
        HerdrLayoutTabBridge.renameMirroredLayoutTabIfChanged(
            workspace: self,
            layoutTabId: layout.id,
            title: title
        )
    }

    func syncTopLevelTabMetadata(forPanelId panelId: UUID) {
        guard let layout = layoutTab(containingPanelId: panelId) else { return }
        syncTopLevelTabMetadata(for: layout)
    }

    func syncTopLevelTabMetadataForAllLayoutTabs() {
        for layout in layoutTabs {
            syncTopLevelTabMetadata(for: layout)
        }
    }

    // MARK: - Private helpers

    /// Resolve the current selected panel inside a layout tab, walking its
    /// panes in order (focused pane first).
    fileprivate func selectedPanelId(in layout: WorkspaceLayoutTab) -> UUID? {
        let controller = layout.bonsplitController
        if let focusedPane = controller.focusedPaneId,
           let tabId = controller.selectedTab(inPane: focusedPane)?.id,
           let panelId = layout.surfaceIdToPanelId[tabId] {
            return panelId
        }
        for paneId in controller.allPaneIds {
            guard let tabId = controller.selectedTab(inPane: paneId)?.id,
                  let panelId = layout.surfaceIdToPanelId[tabId] else { continue }
            return panelId
        }
        return layout.surfaceIdToPanelId.values.first
    }

    /// After swapping the active layout tab, walk into the new bonsplit tree
    /// and reassert selection/focus so the terminal/browser inside it
    /// regains firstResponder.
    fileprivate func applySelectedTopLevelTabFocus(reassertAppKitFocus: Bool = true) {
        let layout = activeLayoutTab
        syncTopLevelTabMetadata(for: layout)
        let controller = layout.bonsplitController
        guard let paneId = controller.focusedPaneId ?? controller.allPaneIds.first,
              let tabId = controller.selectedTab(inPane: paneId)?.id
                ?? controller.tabs(inPane: paneId).first?.id else { return }
        if controller.focusedPaneId != paneId {
            controller.focusPane(paneId)
        }
        if controller.selectedTab(inPane: paneId)?.id != tabId {
            controller.selectTab(tabId)
        }
        applyTabSelection(tabId: tabId, inPane: paneId, reassertAppKitFocus: reassertAppKitFocus)
    }

    /// Wire the delegate callbacks of a per-layout bonsplit controller into
    /// the workspace. Called once for each layout tab's bonsplit at creation
    /// time and again at session-restore time.
    func configureLayoutController(_ controller: BonsplitController) {
        controller.contextMenuShortcuts = Self.buildContextMenuShortcuts()
        controller.onExternalTabDrop = { [weak self] request in
            self?.handleExternalTabDrop(request) ?? false
        }
        controller.onExternalFileDrop = { [weak self] request in
            self?.handleExternalFileDrop(request) ?? false
        }
        controller.tabContextMoveDestinationsProvider = { [weak self] tabId, _ in
            self?.bonsplitTabMoveDestinations(for: tabId) ?? []
        }
        controller.tabContextForkConversationAvailabilityProvider = { [weak self] tabId, _ in
            guard let self,
                  let panelId = self.panelIdFromSurfaceId(tabId) else { return .hidden }
            return self.canForkAgentConversationFromPanel(panelId) ? .available : .hidden
        }
        controller.tabContextForkConversationDefaultActionProvider = { _, _ in
            AgentConversationForkDefaultSettings.current().tabContextAction
        }
        controller.onTabCloseRequest = { [weak self] tabId, _, source in
            switch source {
            case .closeButton:
                self?.markTabCloseButtonClose(surfaceId: tabId)
            case .middleClick:
                self?.markExplicitClose(surfaceId: tabId)
            }
        }
        controller.onTabZoomToggleRequest = { [weak self] tabId, _ in
            guard let self,
                  let panelId = self.panelIdFromSurfaceId(tabId) else { return false }
            return self.toggleSplitZoom(panelId: panelId)
        }
        controller.onTabFullWidthToggleRequest = { [weak self] tabId, _ in
            guard let self,
                  let panelId = self.panelIdFromSurfaceId(tabId) else { return false }
            return self.toggleFullWidthTabMode(panelId: panelId)
        }
        controller.delegate = self
    }
}

// Workspace stored state needed by the top-tab machinery. Kept in a private
// side-store to avoid growing the main `class Workspace` declaration.
@MainActor
private final class WorkspaceTopTabState {
    var isApplyingSelection = false
    var forceCloseTopTabIds: Set<TabID> = []
}

private var workspaceTopTabStateKey: UInt8 = 0

@MainActor
extension Workspace {
    private var topTabState: WorkspaceTopTabState {
        if let existing = objc_getAssociatedObject(self, &workspaceTopTabStateKey) as? WorkspaceTopTabState {
            return existing
        }
        let new = WorkspaceTopTabState()
        objc_setAssociatedObject(self, &workspaceTopTabStateKey, new, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return new
    }

    fileprivate var isApplyingTopLevelTabSelection: Bool {
        get { topTabState.isApplyingSelection }
        set { topTabState.isApplyingSelection = newValue }
    }

    fileprivate var forceCloseTopLevelTabIds: Set<TabID> {
        get { topTabState.forceCloseTopTabIds }
        set { topTabState.forceCloseTopTabIds = newValue }
    }
}
