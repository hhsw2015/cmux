import Foundation

/// Builds the right `HerdrTransport` for a given `HerdrHost`. Centralizes
/// the localUDS↔sshStdio switch so call sites that need a fresh transport
/// (per-RPC dispatchers, the events.subscribe pump, the workspace api
/// client) don't each have to know about transport variants.
enum HerdrTransportFactory {
    static func make(host: HerdrHost) -> any HerdrTransport {
        switch host.transport {
        case .localUDS:
            return LocalUDSTransport(socketPath: host.localApiSocketPath)
        case .sshStdio:
            return SSHStdioTransport(host: host)
        }
    }
}
