import Foundation

extension ContentView {
    func appendHerdrCommandContributions(
        to contributions: inout [CommandPaletteCommandContribution]
    ) {
        func constant(_ value: String) -> (CommandPaletteContextSnapshot) -> String {
            { _ in value }
        }

        let herdrSubtitle = constant(String(
            localized: "command.herdr.subtitle",
            defaultValue: "Computers"
        ))

        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.openHerdrWorkspace.localhost",
                title: constant(String(
                    localized: "command.openHerdrWorkspace.localhost.title",
                    defaultValue: "Open Workspace on This Mac"
                )),
                subtitle: herdrSubtitle,
                shortcutHint: "⌥⌘H",
                keywords: ["herdr", "open", "workspace", "localhost", "attach"]
            )
        )

        for host in HostRegistry.shared.hosts where !host.isLocalhost {
            let displayName = host.displayName
            contributions.append(
                CommandPaletteCommandContribution(
                    commandId: "palette.openHerdrWorkspace.host.\(host.id.uuidString)",
                    title: constant(String(
                        localized: "command.openHerdrWorkspace.host.title",
                        defaultValue: "Open Workspace on \(displayName)"
                    )),
                    subtitle: herdrSubtitle,
                    keywords: ["herdr", "open", "workspace", "host", "remote", displayName]
                )
            )
        }

        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.jumpToBlockedHerdrWorkspace",
                title: constant(String(
                    localized: "command.jumpToBlockedHerdrWorkspace.title",
                    defaultValue: "Jump to Next Workspace Waiting on You"
                )),
                subtitle: herdrSubtitle,
                shortcutHint: "⌥⌘J",
                keywords: ["herdr", "jump", "next", "blocked", "agent", "waiting"]
            )
        )

        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.killCurrentHerdrWorkspace",
                title: constant(String(
                    localized: "command.killCurrentHerdrWorkspace.title",
                    defaultValue: "Close Current Workspace"
                )),
                subtitle: herdrSubtitle,
                shortcutHint: "⌥⇧⌘K",
                keywords: ["herdr", "kill", "close", "current", "workspace", "destroy"]
            )
        )

        for session in HerdrSessionDiscovery.shared.sessions {
            let name = session.name
            let runningHint = session.isRunning ? " (running)" : ""
            contributions.append(
                CommandPaletteCommandContribution(
                    commandId: "palette.attachHerdrSession.\(name)",
                    title: constant(String(
                        localized: "command.attachHerdrSession.title",
                        defaultValue: "Attach to herdr session '\(name)'\(runningHint)"
                    )),
                    subtitle: herdrSubtitle,
                    keywords: ["herdr", "attach", "session", "local", name]
                )
            )
        }

        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.discoverHerdrSessions",
                title: constant(String(
                    localized: "command.discoverHerdrSessions.title",
                    defaultValue: "Refresh herdr session list"
                )),
                subtitle: herdrSubtitle,
                keywords: ["herdr", "discover", "list", "sessions", "refresh"]
            )
        )

        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.refreshAllHerdrHosts",
                title: constant(String(
                    localized: "command.refreshAllHerdrHosts.title",
                    defaultValue: "Refresh Computers"
                )),
                subtitle: herdrSubtitle,
                shortcutHint: "⌥⌘R",
                keywords: ["herdr", "refresh", "reload", "hosts", "all"]
            )
        )

        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.installHerdrCmux",
                title: constant(String(
                    localized: "command.installHerdrCmux.title",
                    defaultValue: "Reinstall agent on first remote computer"
                )),
                subtitle: herdrSubtitle,
                keywords: ["herdr", "install", "remote", "cmux", "agent", "deploy", "reinstall"]
            )
        )
    }

    func registerHerdrCommandHandlers(_ registry: inout CommandPaletteHandlerRegistry) {
        registry.register(commandId: "palette.openHerdrWorkspace.localhost") {
            HerdrPanelOpener.openLocalhostWorkspace()
        }
        for host in HostRegistry.shared.hosts where !host.isLocalhost {
            let capturedHost = host
            registry.register(
                commandId: "palette.openHerdrWorkspace.host.\(host.id.uuidString)"
            ) {
                HerdrPanelOpener.openWorkspace(host: capturedHost)
            }
        }
        registry.register(commandId: "palette.jumpToBlockedHerdrWorkspace") {
            HerdrJumpCommands.jumpToNextBlockedWorkspace()
        }
        registry.register(commandId: "palette.killCurrentHerdrWorkspace") {
            HerdrKillCommands.killCurrentWorkspace()
        }
        registry.register(commandId: "palette.refreshAllHerdrHosts") {
            for host in HostRegistry.shared.hosts {
                HerdrWorkspaceListStore.shared.refresh(host: host)
            }
        }
        registry.register(commandId: "palette.discoverHerdrSessions") {
            HerdrSessionDiscovery.shared.refresh()
        }
        for session in HerdrSessionDiscovery.shared.sessions {
            let capturedSession = session
            registry.register(
                commandId: "palette.attachHerdrSession.\(session.name)"
            ) {
                guard let host = HerdrSessionDiscovery.shared.ensureHost(for: capturedSession) else {
                    return
                }
                HerdrPanelOpener.openWorkspace(host: host)
            }
        }
        registry.register(commandId: "palette.installHerdrCmux") {
            HerdrRemoteInstaller.installOnFirstRemoteHost()
        }
    }
}
