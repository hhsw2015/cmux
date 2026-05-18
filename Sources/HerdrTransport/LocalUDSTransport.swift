import Darwin
import Foundation

/// Transport over a Unix domain socket on the same machine. Used to
/// reach a localhost herdr daemon (api or display socket).
///
/// Reading happens on a dedicated background thread that loops on
/// `read(2)`; bytes are forwarded to `incoming` as `Data` chunks.
actor LocalUDSTransport: HerdrTransport {
    private let socketPath: String
    private(set) var status: HerdrTransportStatus = .disconnected
    let incoming: AsyncStream<Data>
    private let incomingContinuation: AsyncStream<Data>.Continuation

    private var fd: Int32 = -1
    private var readerTask: Task<Void, Never>?

    init(socketPath: String) {
        self.socketPath = socketPath
        var continuation: AsyncStream<Data>.Continuation!
        self.incoming = AsyncStream { c in continuation = c }
        self.incomingContinuation = continuation
    }

    func connect() async throws {
        guard fd == -1 else {
            throw HerdrTransportError.alreadyConnected
        }
        status = .connecting

        let socketFd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard socketFd >= 0 else {
            let err = errno
            status = .error("socket(AF_UNIX): errno \(err)")
            throw HerdrTransportError.socketCreate(err)
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8)
        let maxLen = MemoryLayout.size(ofValue: addr.sun_path)
        guard pathBytes.count < maxLen else {
            close_(socketFd)
            status = .error("socket path too long: \(socketPath)")
            throw HerdrTransportError.pathTooLong
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { pathPtr in
            pathPtr.withMemoryRebound(to: CChar.self, capacity: maxLen) { rebound in
                for i in 0..<pathBytes.count {
                    rebound[i] = CChar(bitPattern: pathBytes[i])
                }
                rebound[pathBytes.count] = 0
            }
        }
        let connectResult = withUnsafePointer(to: &addr) { addrPtr -> Int32 in
            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                Darwin.connect(socketFd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connectResult == 0 else {
            let err = errno
            close_(socketFd)
            status = .error("connect: errno \(err)")
            throw HerdrTransportError.socketConnect(err)
        }

        self.fd = socketFd
        status = .online
        startReader()
    }

    func send(_ data: Data) async throws {
        guard fd != -1 else {
            throw HerdrTransportError.notConnected
        }
        let captured = data
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async { [fd] in
                var written = 0
                let total = captured.count
                let result = captured.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Int32 in
                    guard let base = raw.baseAddress else { return 0 }
                    while written < total {
                        let chunk = total - written
                        let n = Darwin.write(
                            fd,
                            base.advanced(by: written),
                            chunk
                        )
                        if n < 0 {
                            return errno
                        }
                        if n == 0 {
                            return EIO
                        }
                        written += n
                    }
                    return 0
                }
                if result == 0 {
                    cont.resume(returning: ())
                } else {
                    cont.resume(throwing: HerdrTransportError.socketWrite(result))
                }
            }
        }
    }

    func close() async {
        if fd != -1 {
            close_(fd)
            fd = -1
        }
        readerTask?.cancel()
        readerTask = nil
        incomingContinuation.finish()
        status = .disconnected
    }

    private func startReader() {
        let descriptor = fd
        let cont = incomingContinuation
        readerTask = Task.detached(priority: .userInitiated) {
            let bufferSize = 16 * 1024
            var buffer = [UInt8](repeating: 0, count: bufferSize)
            while !Task.isCancelled {
                let n = buffer.withUnsafeMutableBufferPointer { ptr -> Int in
                    Darwin.read(descriptor, ptr.baseAddress, bufferSize)
                }
                if n > 0 {
                    let chunk = Data(buffer.prefix(n))
                    cont.yield(chunk)
                } else if n == 0 {
                    // EOF — peer closed.
                    cont.finish()
                    return
                } else {
                    // -1 — error or interrupted; treat as fatal for PoC.
                    cont.finish()
                    return
                }
            }
            cont.finish()
        }
    }
}

/// Disambiguate Foundation's `close` helper (none) from POSIX `close` so
/// callers don't accidentally invoke a different overload through
/// `Darwin.close` shadowing.
@inline(__always)
private func close_(_ fd: Int32) {
    _ = Darwin.close(fd)
}
