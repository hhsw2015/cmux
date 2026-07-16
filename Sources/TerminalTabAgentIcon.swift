import AppKit
import Bonsplit
import CmuxAppKitSupportUI
import Foundation

struct TerminalTabAgentIconPayload: Equatable {
    let imageData: Data?
    let assetName: String?
}

@MainActor
fileprivate func terminalTabAgentIconImageData(assetName: String) -> Data? {
    CmuxResolvedIconRenderer().pngData(
        for: CmuxResolvedIconRequest(
            source: .asset(name: assetName, bundle: .main),
            size: NSSize(width: 14, height: 14)
        ),
        appearance: NSApplication.shared.effectiveAppearance
    )
}

/// Resolves the asset-catalog brand mark shown in a terminal tab's fixed icon
/// slot from the panel's agent state: live agents win over a restored
/// (resumable) agent snapshot, and among several recognized live agents the
/// most recently started process wins, matching "the newest agent is the one
/// the user launched last". Registry-owned agents (Vault registrations,
/// including project-config overrides) resolve through their registration's
/// `iconAssetName` so this file never becomes a second source of truth for
/// registered-agent branding.
nonisolated struct TerminalTabAgentIconResolver {
    /// One live agent candidate: its normalized status key plus the recorded
    /// process start identity used to order concurrent agents by recency.
    struct LiveAgent {
        let statusKey: String
        let processStart: AgentPIDProcessIdentity?
    }

    /// A restored (resumable) agent snapshot's icon inputs. The registration
    /// icon, when present, is authoritative: registrations can override
    /// built-in agents (e.g. project-config pi/grok) and carry custom agents
    /// the built-in switch cannot know about.
    struct RestoredAgent {
        let kind: String
        let registrationIconAssetName: String?
    }

    /// - Parameter registrationIconAssetName: In-memory lookup for registered
    ///   agent ids (callers back it with the panel's restorable-agent
    ///   registration; it must never do I/O — icon sync runs on the agent
    ///   PID/status mutation path). Consulted before the built-in switch so
    ///   config registrations can override built-in agents, matching
    ///   `CmuxVaultAgentRegistry` override semantics and the restored path.
    func assetName(
        liveAgents: [LiveAgent],
        titleDerivedStatusKey: String? = nil,
        restoredAgent: RestoredAgent?,
        registrationIconAssetName: (String) -> String? = { _ in nil }
    ) -> String? {
        let recognized = liveAgents.compactMap { agent -> (agent: LiveAgent, asset: String)? in
            let asset = registrationIconAssetName(agent.statusKey)
                ?? builtInAssetName(statusKey: agent.statusKey)
            return asset.map { (agent: agent, asset: $0) }
        }
        if let newest = recognized.min(by: { Self.isOrderedByRecency($0.agent, $1.agent) }) {
            return newest.asset
        }
        if let titleDerivedStatusKey,
           let titleDerivedAsset = registrationIconAssetName(titleDerivedStatusKey)
            ?? builtInAssetName(statusKey: titleDerivedStatusKey) {
            return titleDerivedAsset
        }
        guard let restoredAgent else { return nil }
        return restoredAgent.registrationIconAssetName ?? builtInAssetName(statusKey: restoredAgent.kind)
    }

    func payload(assetName: String?, imageData: (String) -> Data?) -> TerminalTabAgentIconPayload {
        guard let assetName else {
            return TerminalTabAgentIconPayload(imageData: nil, assetName: nil)
        }
        if let renderedData = imageData(assetName) {
            return TerminalTabAgentIconPayload(imageData: renderedData, assetName: nil)
        }
        return TerminalTabAgentIconPayload(imageData: nil, assetName: assetName)
    }

    /// - Parameter knownStatusKeys: Status keys known to be exact agent ids
    ///   (e.g. the keys of the runtime's status entries). Registered agent ids
    ///   may legally contain dots, so a raw PID key is only truncated at its
    ///   first dot when it is not itself a known status key — mirroring
    ///   `Workspace.agentStatusKey(forAgentPIDKey:)`, which exact-matches
    ///   against `statusEntries` before falling back to the prefix.
    func assetName(
        agentPIDKeys: Set<String>,
        processIdentities: [String: AgentPIDProcessIdentity] = [:],
        knownStatusKeys: Set<String> = [],
        titleDerivedStatusKey: String? = nil,
        restoredAgent: RestoredAgent?,
        registrationIconAssetName: (String) -> String? = { _ in nil }
    ) -> String? {
        assetName(
            liveAgents: agentPIDKeys.map { key in
                LiveAgent(
                    statusKey: knownStatusKeys.contains(key) ? key : statusKey(forAgentPIDKey: key),
                    processStart: processIdentities[key]
                )
            },
            titleDerivedStatusKey: titleDerivedStatusKey,
            restoredAgent: restoredAgent,
            registrationIconAssetName: registrationIconAssetName
        )
    }

    func titleDerivedStatusKey(title: String) -> String? {
        guard let token = title.split(whereSeparator: { $0.isWhitespace }).first else { return nil }
        let executable = String(token)
        guard !executable.contains("/") else { return nil }
        return Self.titleExecutableStatusKeys[executable]
    }

    func updateTitleDerivedStatusKey(
        forPanelId panelId: UUID,
        title: String,
        in statusKeysByPanelId: inout [UUID: String]
    ) -> Bool {
        let statusKey = titleDerivedStatusKey(title: title)
        if statusKeysByPanelId[panelId] == statusKey {
            return false
        }
        if let statusKey {
            statusKeysByPanelId[panelId] = statusKey
        } else {
            statusKeysByPanelId.removeValue(forKey: panelId)
        }
        return true
    }

    /// Newest process start first; agents with a recorded start identity rank
    /// ahead of agents without one; equal recency falls back to ascending
    /// status key so the choice stays deterministic.
    private static func isOrderedByRecency(_ lhs: LiveAgent, _ rhs: LiveAgent) -> Bool {
        switch (lhs.processStart, rhs.processStart) {
        case let (lhsStart?, rhsStart?):
            if lhsStart.startSeconds != rhsStart.startSeconds {
                return lhsStart.startSeconds > rhsStart.startSeconds
            }
            if lhsStart.startMicroseconds != rhsStart.startMicroseconds {
                return lhsStart.startMicroseconds > rhsStart.startMicroseconds
            }
        case (.some, .none):
            return true
        case (.none, .some):
            return false
        case (.none, .none):
            break
        }
        return lhs.statusKey < rhs.statusKey
    }

    private func statusKey(forAgentPIDKey key: String) -> String {
        key.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init) ?? key
    }

    private func builtInAssetName(statusKey: String) -> String? {
        Self.builtInAssetNamesByStatusKey[statusKey]
    }

    private static let titleExecutableStatusKeys: [String: String] = [
        "claude": "claude",
        "codex": "codex",
        "opencode": "opencode",
        "pi": "pi",
        "omp": "omp",
    ]

    private static let builtInAssetNamesByStatusKey: [String: String] = [
        "claude": "AgentIcons/Claude",
        "claude_code": "AgentIcons/Claude",
        "codex": "AgentIcons/Codex",
        "opencode": "AgentIcons/OpenCode",
        "pi": "AgentIcons/Pi",
        "omp": "AgentIcons/Pi",
        "grok": "AgentIcons/Grok",
        "rovodev": "AgentIcons/RovoDev",
        "antigravity": "AgentIcons/Antigravity",
        "hermes-agent": "AgentIcons/HermesAgent",
    ]
}

extension TerminalTabAgentIconResolver.RestoredAgent {
    init(snapshot: SessionRestorableAgentSnapshot) {
        self.init(
            kind: snapshot.kind.rawValue,
            registrationIconAssetName: snapshot.registration?.iconAssetName
        )
    }
}

extension DockSplitStore {
    func updateTitleDerivedTerminalAgentStatusKey(forPanelId panelId: UUID, title: String) -> Bool {
        TerminalTabAgentIconResolver().updateTitleDerivedStatusKey(
            forPanelId: panelId,
            title: title,
            in: &titleDerivedAgentStatusKeysByPanelId
        )
    }

    /// Dock tabs resolve from the detached transfer snapshot: the Dock
    /// receives no agent lifecycle updates by design (same contract as the
    /// transfer's resume metadata), and `detachSurface` re-reconciles agent
    /// state, dropping proven-exited agents, when the surface leaves the Dock.
    func terminalTabAgentIconAsset(forPanelId panelId: UUID) -> String? {
        let transfer = detachedSurfaceTransfersByPanelId[panelId]
        let registration = transfer?.restorableAgent?.registration
        return TerminalTabAgentIconResolver().assetName(
            agentPIDKeys: transfer?.agentRuntime?.agentPIDKeys ?? [],
            processIdentities: transfer?.agentRuntime?.agentPIDProcessIdentities ?? [:],
            knownStatusKeys: transfer?.agentRuntime.map { Set($0.statusEntries.keys) } ?? [],
            titleDerivedStatusKey: titleDerivedAgentStatusKeysByPanelId[panelId],
            restoredAgent: transfer?.restorableAgent.map(
                TerminalTabAgentIconResolver.RestoredAgent.init(snapshot:)
            ),
            registrationIconAssetName: { statusKey in
                registration?.id == statusKey ? registration?.iconAssetName : nil
            }
        )
    }

    @MainActor
    func terminalTabAgentIconPayload(forPanelId panelId: UUID) -> TerminalTabAgentIconPayload {
        TerminalTabAgentIconResolver().payload(
            assetName: terminalTabAgentIconAsset(forPanelId: panelId),
            imageData: terminalTabAgentIconImageData(assetName:)
        )
    }

    func syncTerminalTabAgentIconAssetsForAllTerminalPanels() {
        for (panelId, panel) in panels where panel is TerminalPanel {
            guard let tabId = surfaceId(forPanelId: panelId),
                  let existing = bonsplitController.tab(tabId) else {
                continue
            }
            let payload = terminalTabAgentIconPayload(forPanelId: panelId)
            guard existing.iconImageData != payload.imageData || existing.iconAsset != payload.assetName else {
                continue
            }
            bonsplitController.updateTab(tabId, iconImageData: .some(payload.imageData), iconAsset: .some(payload.assetName))
        }
    }
}
