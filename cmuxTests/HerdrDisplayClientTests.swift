import XCTest
@testable import cmux

/// Behavior tests for HerdrDisplayClient's reconnect supervisor.
///
/// We avoid spawning real `raw-pty-attach` (would require a herdr
/// daemon) by injecting a fake spawn closure. The fake returns a
/// HerdrDisplaySpawnHandle whose Process is `/bin/sleep 3600` and
/// whose pipes the test controls directly: writing to the test's
/// stdoutWriter end produces "PTY output" that the client's reader
/// task observes; closing the stdoutWriter end produces an EOF that
/// kicks the supervisor into a reconnect attempt.
///
/// Each spawn invocation is recorded so tests can assert on attempt
/// count and the takeover flag (which must be true on every
/// reconnect — see HerdrDisplayClient.runSupervisor).
@MainActor
final class HerdrDisplayClientTests: XCTestCase {

    // MARK: - fake spawn

    /// One spawn observation. The pipes' opposite-end handles are kept
    /// here so the test can drive output / EOF / process exit from the
    /// "server" side without poking client-internal state.
    final class SpawnRecord {
        let takeover: Bool
        let stdinReader: FileHandle
        let stdoutWriter: FileHandle
        let stderrWriter: FileHandle
        let process: Process
        init(takeover: Bool, stdinReader: FileHandle, stdoutWriter: FileHandle, stderrWriter: FileHandle, process: Process) {
            self.takeover = takeover
            self.stdinReader = stdinReader
            self.stdoutWriter = stdoutWriter
            self.stderrWriter = stderrWriter
            self.process = process
        }
    }

    final class SpawnRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _records: [SpawnRecord] = []
        var failNextN: Int = 0
        struct InjectedFailure: Error {}

        var records: [SpawnRecord] {
            lock.lock(); defer { lock.unlock() }
            return _records
        }

        func append(_ r: SpawnRecord) {
            lock.lock(); defer { lock.unlock() }
            _records.append(r)
        }

        func consumeFailure() -> Bool {
            lock.lock(); defer { lock.unlock() }
            guard failNextN > 0 else { return false }
            failNextN -= 1
            return true
        }
    }

    private func makeFakeSpawn(recorder: SpawnRecorder) -> HerdrDisplayClient.SpawnFunc {
        return { takeover in
            if recorder.consumeFailure() {
                throw SpawnRecorder.InjectedFailure()
            }
            let stdinPipe = Pipe()
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/bin/sleep")
            proc.arguments = ["3600"]
            proc.standardInput = stdinPipe
            proc.standardOutput = stdoutPipe
            proc.standardError = stderrPipe
            try proc.run()

            recorder.append(SpawnRecord(
                takeover: takeover,
                stdinReader: stdinPipe.fileHandleForReading,
                stdoutWriter: stdoutPipe.fileHandleForWriting,
                stderrWriter: stderrPipe.fileHandleForWriting,
                process: proc
            ))
            return HerdrDisplaySpawnHandle(
                process: proc,
                stdin: stdinPipe.fileHandleForWriting,
                stdout: stdoutPipe.fileHandleForReading,
                stderr: stderrPipe.fileHandleForReading
            )
        }
    }

    private func makeClient(recorder: SpawnRecorder) -> HerdrDisplayClient {
        HerdrDisplayClient(
            host: .localhost(),
            terminalId: "t-test-1",
            executablePath: "/usr/bin/true",
            cols: 80,
            rows: 24,
            spawn: makeFakeSpawn(recorder: recorder)
        )
    }

    // MARK: - tests

    func testFirstStartReachesConnectedAndForwardsBytes() async throws {
        let recorder = SpawnRecorder()
        let client = makeClient(recorder: recorder)
        try await client.start()
        defer { client.stop() }

        XCTAssertEqual(client.state, .connected)
        XCTAssertEqual(recorder.records.count, 1)
        XCTAssertFalse(recorder.records.first!.takeover, "first attach must not request takeover")

        // Server-side writes a chunk; reader/output stream must
        // surface it.
        let writer = recorder.records.first!.stdoutWriter
        try writer.write(contentsOf: Data("hello".utf8))
        let received = try await firstChunk(from: client.output, timeoutSeconds: 2.0)
        XCTAssertEqual(received, Data("hello".utf8))
    }

    func testEofTriggersReconnectWithTakeover() async throws {
        let recorder = SpawnRecorder()
        let client = makeClient(recorder: recorder)
        try await client.start()
        defer { client.stop() }
        XCTAssertEqual(recorder.records.count, 1)

        // Simulate subprocess EOF by closing the server-side stdout
        // writer; the reader task hits availableData == empty and
        // signals the supervisor.
        try recorder.records[0].stdoutWriter.close()
        recorder.records[0].process.terminate()

        // Supervisor backoff is 250ms minimum. Poll up to 5s for the
        // second spawn.
        try await waitUntil(timeoutSeconds: 5.0, predicate: {
            recorder.records.count >= 2
        })
        XCTAssertEqual(recorder.records.count, 2)
        XCTAssertTrue(recorder.records[1].takeover, "reconnect must use --takeover")
    }

    func testStopBeforeReconnectPreventsFurtherSpawns() async throws {
        let recorder = SpawnRecorder()
        let client = makeClient(recorder: recorder)
        try await client.start()
        XCTAssertEqual(recorder.records.count, 1)

        // Trigger EOF then stop() while supervisor is in its 250ms
        // backoff sleep — supervisor must observe `stopped` and bail.
        try recorder.records[0].stdoutWriter.close()
        recorder.records[0].process.terminate()
        client.stop()

        // Wait through several backoff cycles to confirm no respawn.
        try await Task.sleep(nanoseconds: 1_500_000_000)
        XCTAssertEqual(recorder.records.count, 1, "stop() must prevent further spawns")
        XCTAssertEqual(client.state, .stopped)
    }

    func testInjectedSpawnFailureCountsAgainstAttemptCap() async throws {
        let recorder = SpawnRecorder()
        let client = HerdrDisplayClient(
            host: .localhost(),
            terminalId: "t-cap",
            executablePath: "/usr/bin/true",
            cols: 80,
            rows: 24,
            spawn: makeFakeSpawn(recorder: recorder)
        )
        try await client.start()
        defer { client.stop() }
        XCTAssertEqual(recorder.records.count, 1)

        // Make the next reconnect attempt fail, then succeed. The
        // supervisor must retry on the failure (no give-up) and
        // settle on the second spawn.
        recorder.failNextN = 1
        try recorder.records[0].stdoutWriter.close()
        recorder.records[0].process.terminate()

        try await waitUntil(timeoutSeconds: 6.0, predicate: {
            // First spawn (initial) + 1 successful reconnect; the
            // failed attempt produced no record because the closure
            // threw before reaching the recorder.
            recorder.records.count >= 2
        })
        XCTAssertEqual(client.state, .connected)
    }

    func testBackoffDelayCapsAtEightSeconds() {
        XCTAssertEqual(HerdrDisplayClient.backoffDelay(attempt: 1), 250 * 1_000_000)
        XCTAssertEqual(HerdrDisplayClient.backoffDelay(attempt: 2), 500 * 1_000_000)
        XCTAssertEqual(HerdrDisplayClient.backoffDelay(attempt: 3), 1_000 * 1_000_000)
        XCTAssertEqual(HerdrDisplayClient.backoffDelay(attempt: 4), 2_000 * 1_000_000)
        XCTAssertEqual(HerdrDisplayClient.backoffDelay(attempt: 5), 4_000 * 1_000_000)
        XCTAssertEqual(HerdrDisplayClient.backoffDelay(attempt: 6), 8_000 * 1_000_000)
        XCTAssertEqual(HerdrDisplayClient.backoffDelay(attempt: 10), 8_000 * 1_000_000)
        XCTAssertEqual(HerdrDisplayClient.backoffDelay(attempt: 20), 8_000 * 1_000_000)
    }

    // MARK: - helpers

    private func firstChunk(
        from stream: AsyncStream<Data>,
        timeoutSeconds: TimeInterval
    ) async throws -> Data {
        try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask {
                for await chunk in stream { return chunk }
                return Data()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                throw TimeoutError()
            }
            let first = try await group.next()!
            group.cancelAll()
            return first
        }
    }

    private func waitUntil(
        timeoutSeconds: TimeInterval,
        predicate: @escaping @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if predicate() { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail("predicate not satisfied within \(timeoutSeconds)s")
    }

    private struct TimeoutError: Error {}
}
