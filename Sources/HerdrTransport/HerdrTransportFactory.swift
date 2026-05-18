import Foundation

/// Builds the right `HerdrTransport` for a given `HerdrHost`. Centralizes
/// the localUDS↔sshStdio switch so call sites that need a fresh transport
/// (per-RPC dispatchers, the events.subscribe pump, the workspace api
/// client) don't each have to know about transport variants.
enum HerdrTransportFactory {
    static func make(host: HerdrHost) -> any HerdrTransport {
        switch host.transport {
        case .localUDS:
            let socketPath = (("~/.config/herdr/sessions/" + host.sessionName + "/herdr.sock") as NSString)
                .expandingTildeInPath
            return LocalUDSTransport(socketPath: socketPath)
        case .sshStdio(let target):
            return SSHStdioTransport(
                target: target,
                sessionName: host.sessionName
            )
        }
    }
}
