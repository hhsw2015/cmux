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
            defaultValue: "Herdr"
        ))

        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.openHerdrWorkspace.localhost",
                title: constant(String(
                    localized: "command.openHerdrWorkspace.localhost.title",
                    defaultValue: "Open Herdr Workspace (localhost)"
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
                        defaultValue: "Open Herdr Workspace on \(displayName)"
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
                    defaultValue: "Jump to Next Blocked Herdr Workspace"
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
                    defaultValue: "Kill Current Herdr Workspace"
                )),
                subtitle: herdrSubtitle,
                shortcutHint: "⌥⇧⌘K",
                keywords: ["herdr", "kill", "close", "current", "workspace", "destroy"]
            )
        )

        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.refreshAllHerdrHosts",
                title: constant(String(
                    localized: "command.refreshAllHerdrHosts.title",
                    defaultValue: "Refresh All Herdr Hosts"
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
                    defaultValue: "Install herdr-cmux on First Remote Host"
                )),
                subtitle: herdrSubtitle,
                keywords: ["herdr", "install", "remote", "cmux", "scp", "deploy"]
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
        registry.register(commandId: "palette.installHerdrCmux") {
            HerdrRemoteInstaller.installOnFirstRemoteHost()
        }
    }
}
