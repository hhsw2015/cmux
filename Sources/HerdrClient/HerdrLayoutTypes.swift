import Foundation

/// Direction of a BSP split node, matching herdr's wire schema.
enum HerdrLayoutSplitDirection: String, Codable, Sendable {
    case horizontal
    case vertical
}

/// Mirror of herdr's `LayoutNode` wire DTO. `Pane` leaves carry the
/// public pane id (e.g. `w1-3`); `Split` interior nodes carry direction,
/// ratio, and recursive children. JSON tag is `kind`.
indirect enum HerdrLayoutNode: Codable, Equatable, Sendable {
    case pane(paneId: String)
    case split(
        direction: HerdrLayoutSplitDirection,
        ratio: Float,
        first: HerdrLayoutNode,
        second: HerdrLayoutNode
    )

    private enum CodingKeys: String, CodingKey {
        case kind
        case paneId = "pane_id"
        case direction
        case ratio
        case first
        case second
    }

    private enum Kind: String, Codable {
        case pane
        case split
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .pane:
            self = .pane(paneId: try container.decode(String.self, forKey: .paneId))
        case .split:
            self = .split(
                direction: try container.decode(HerdrLayoutSplitDirection.self, forKey: .direction),
                ratio: try container.decode(Float.self, forKey: .ratio),
                first: try container.decode(HerdrLayoutNode.self, forKey: .first),
                second: try container.decode(HerdrLayoutNode.self, forKey: .second)
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .pane(let paneId):
            try container.encode(Kind.pane, forKey: .kind)
            try container.encode(paneId, forKey: .paneId)
        case .split(let direction, let ratio, let first, let second):
            try container.encode(Kind.split, forKey: .kind)
            try container.encode(direction, forKey: .direction)
            try container.encode(ratio, forKey: .ratio)
            try container.encode(first, forKey: .first)
            try container.encode(second, forKey: .second)
        }
    }
}

/// Snapshot of one tab's BSP layout. Splits are addressed by L/R paths
/// (sequence of bools, false=first, true=second) — clients walk the tree
/// to derive the path of a particular split rather than holding stable
/// split ids.
struct HerdrLayoutTree: Codable, Equatable, Sendable {
    let workspaceId: String
    let tabId: String
    let root: HerdrLayoutNode
    let focusedPaneId: String?

    private enum CodingKeys: String, CodingKey {
        case workspaceId = "workspace_id"
        case tabId = "tab_id"
        case root
        case focusedPaneId = "focused_pane_id"
    }
}

/// Payload of the `layout.changed` event broadcast after any structural
/// mutation in a tab's layout. Just wraps the new tree.
struct HerdrLayoutChangedPayload: Codable, Equatable, Sendable {
    let tree: HerdrLayoutTree
}

/// Payload of the `tab.reordered` event broadcast after `tab.reorder`.
struct HerdrTabReorderedPayload: Codable, Equatable, Sendable {
    let workspaceId: String
    let tabIds: [String]

    private enum CodingKeys: String, CodingKey {
        case workspaceId = "workspace_id"
        case tabIds = "tab_ids"
    }
}

/// Payload of the `workspace.closed` event broadcast after `workspace.close`.
struct HerdrWorkspaceClosedPayload: Codable, Equatable, Sendable {
    let workspaceId: String

    private enum CodingKeys: String, CodingKey {
        case workspaceId = "workspace_id"
    }
}

extension HerdrApiClient {
    /// Fetch the current BSP tree for one tab. Used on attach to
    /// initialize cmux's bonsplit mirror; subsequent updates come from
    /// the `layout.changed` subscription.
    func layoutSnapshot(workspaceId: String, tabId: String) async throws -> HerdrLayoutTree {
        let result = try await request(
            method: "layout.snapshot",
            params: [
                "workspace_id": workspaceId,
                "tab_id": tabId,
            ]
        )
        return try Self.decodeLayoutTree(from: result)
    }

    /// Adjust the ratio of a split node identified by its root-relative
    /// L/R path. Empty path targets the root split.
    func paneSetSplitRatio(
        workspaceId: String,
        tabId: String,
        path: [Bool],
        ratio: Float
    ) async throws {
        _ = try await request(
            method: "pane.set_split_ratio",
            params: [
                "workspace_id": workspaceId,
                "tab_id": tabId,
                "path": path,
                "ratio": Double(ratio),
            ]
        )
    }

    /// Exchange two panes' positions in the BSP tree without disturbing
    /// the surrounding splits. Both panes must live in the same tab.
    func paneSwap(aPaneId: String, bPaneId: String) async throws {
        _ = try await request(
            method: "pane.swap",
            params: [
                "a_pane_id": aPaneId,
                "b_pane_id": bPaneId,
            ]
        )
    }

    /// Move logical focus to a pane. Server-authoritative; broadcasts a
    /// `pane.focused` event on success.
    func paneFocus(paneId: String) async throws {
        _ = try await request(
            method: "pane.focus",
            params: ["pane_id": paneId]
        )
    }

    /// Permute the tab order of a workspace. The given list must be a
    /// permutation of every existing tab id in the workspace.
    func tabReorder(workspaceId: String, tabIds: [String]) async throws {
        _ = try await request(
            method: "tab.reorder",
            params: [
                "workspace_id": workspaceId,
                "tab_ids": tabIds,
            ]
        )
    }

    static func decodeLayoutTree(from result: [String: Any]) throws -> HerdrLayoutTree {
        guard let treeDict = result["tree"] as? [String: Any] else {
            throw HerdrApiError(code: "malformed", message: "layout.snapshot result missing tree")
        }
        let data = try JSONSerialization.data(withJSONObject: treeDict)
        return try JSONDecoder().decode(HerdrLayoutTree.self, from: data)
    }
}
