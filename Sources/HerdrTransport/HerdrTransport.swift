import Foundation

/// Connection state for a herdr transport. UI surfaces it as a colored
/// dot beside the host row.
enum HerdrTransportStatus: Equatable, Sendable {
    case disconnected
    case connecting
    case online
    case error(String)
}

/// Errors raised by transports. Higher layers map these to user-facing
/// host status changes.
enum HerdrTransportError: Error, Equatable {
    case alreadyConnected
    case notConnected
    case socketCreate(Int32)
    case socketConnect(Int32)
    case socketRead(Int32)
    case socketWrite(Int32)
    case pathTooLong
    case eof
    case other(String)
}

/// Byte-level transport to a herdr daemon. The protocol intentionally
/// works in raw bytes: callers are responsible for whatever framing the
/// target socket uses (line-delimited JSON for the API socket,
/// length-prefixed bincode for the display socket).
///
/// All implementations are actor-isolated so concurrent send / receive
/// callers don't race. `incoming` is a single-consumer AsyncStream of
/// raw bytes — split into lines or frames at a higher layer.
protocol HerdrTransport: Actor {
    var status: HerdrTransportStatus { get }
    var incoming: AsyncStream<Data> { get }

    func connect() async throws
    func send(_ data: Data) async throws
    func close() async
}
