import Foundation
import GnoCore
import os

/// Owns the in-process Go core and turns its promise-block API into Swift
/// concurrency.
///
/// There is no gRPC client here on purpose. `framework/service/service_client.go`
/// resolves the method by reflection against the connect client, decodes the
/// request with `protojson` and encodes the reply with `encoding/json`, base64
/// on the way out. So the whole wire format is: a method name, a JSON string in,
/// a base64 JSON string out. A generated client would add a dependency and buy
/// nothing.
public actor GnoBridge {
    public struct Config: Sendable {
        public var rootDir: String
        public var tmpDir: String

        public init(rootDir: String, tmpDir: String) {
            self.rootDir = rootDir
            self.tmpDir = tmpDir
        }

        /// Documents for the keybase (it must survive app updates and be backed
        /// up), the system temp dir for everything else.
        public static func standard() -> Config {
            let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            return Config(rootDir: documents.path, tmpDir: FileManager.default.temporaryDirectory.path)
        }
    }

    private let logger = Logger(subsystem: "land.gno.moul", category: "bridge")
    private var bridge: GnoGnonativeBridge?

    public init() {}

    // No deinit: closing the Go core is async work an actor's nonisolated
    // deinit cannot do. `stop()` is the way, and the app holds one bridge for
    // its whole lifetime, so there is nothing to reclaim in between.

    public func start(_ config: Config = .standard()) throws {
        guard bridge == nil else { return }

        guard let goConfig = GnoGnonativeBridgeConfig() else {
            throw GnoError.bridge("unable to create the bridge config")
        }
        goConfig.rootDir = config.rootDir
        goConfig.tmpDir = config.tmpDir

        // A simulator cannot create a unix domain socket in the app container,
        // so the core falls back to a loopback TCP listener there. Devices keep
        // the UDS, which no other process on the phone can reach.
        #if targetEnvironment(simulator)
        goConfig.useTcpListener = true
        goConfig.disableUdsListener = true
        #endif

        var err: NSError?
        guard let started = GnoGnonativeNewBridge(goConfig, &err) else {
            throw err.map { GnoError.from($0) } ?? GnoError.bridge("NewBridge returned nil with no error")
        }
        bridge = started
        logger.info("gno core started, rootDir=\(config.rootDir, privacy: .public)")
    }

    public func stop() throws {
        try bridge?.close()
        bridge = nil
    }

    public var isRunning: Bool { bridge != nil }

    // MARK: - Unary

    /// Calls a unary method and returns the raw reply JSON.
    ///
    /// `method` is the Go client method name, resolved by reflection: "Render",
    /// "QuerySessionAccount", "EstimateTxFees". A typo is a runtime error, which
    /// is why nothing outside `GnoClient` should call this directly.
    func invoke(_ method: String, json: String) async throws -> Data {
        let bridge = try requireBridge()
        let reply: String = try await withPromise { promise in
            bridge.invokeGrpcMethod(with: promise, method: method, jsonMessage: json)
        }
        guard let decoded = Data(base64Encoded: reply) else {
            throw GnoError.bridge("reply from \(method) was not base64")
        }
        return decoded
    }

    // MARK: - Streaming

    /// Opens a server stream and returns its id. The caller must close it.
    func openStream(_ method: String, json: String) async throws -> String {
        let bridge = try requireBridge()
        return try await withPromise { promise in
            bridge.createStreamClient(with: promise, method: method, jsonMessage: json)
        }
    }

    /// Reads the next message of a stream. Returns nil when the stream is done.
    func receive(stream id: String) async throws -> Data? {
        let bridge = try requireBridge()
        do {
            let reply: String = try await withPromise { promise in
                bridge.streamClientReceive(with: promise, id_: id)
            }
            guard let decoded = Data(base64Encoded: reply) else {
                throw GnoError.bridge("stream reply was not base64")
            }
            return decoded
        } catch let error as GnoError where error.isStreamEnd {
            return nil
        }
    }

    func closeStream(_ id: String) async {
        guard let bridge else { return }
        _ = try? await withPromise { (promise: PromiseBridge) in
            bridge.closeStreamClient(with: promise, id_: id)
        } as String
    }

    // MARK: - Plumbing

    private func requireBridge() throws -> GnoGnonativeBridge {
        guard let bridge else { throw GnoError.notStarted }
        return bridge
    }

    private func withPromise(_ body: (PromiseBridge) -> Void) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let promise = PromiseBridge(continuation)
            body(promise)
        }
    }
}

/// Bridges one Go promise to one Swift continuation.
///
/// Go holds this across the call, so it keeps itself alive in `livePromises`
/// until it settles: a promise released early is a crash in the Go callback, not
/// a dropped result.
final class PromiseBridge: NSObject, GnoGnonativePromiseBlockProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    /// Guarded by `lock`; the compiler cannot see that, hence the annotation.
    nonisolated(unsafe) private static var live: Set<PromiseBridge> = []

    private let continuation: CheckedContinuation<String, Error>
    private var settled = false

    init(_ continuation: CheckedContinuation<String, Error>) {
        self.continuation = continuation
        super.init()
        Self.lock.withLock { _ = Self.live.insert(self) }
    }

    func callResolve(_ reply: String?) {
        settle {
            if let reply {
                continuation.resume(returning: reply)
            } else {
                continuation.resume(throwing: GnoError.bridge("resolved with a nil reply"))
            }
        }
    }

    func callReject(_ error: Error?) {
        settle {
            continuation.resume(throwing: error.map { GnoError.from($0 as NSError) }
                ?? GnoError.bridge("rejected with a nil error"))
        }
    }

    private func settle(_ resume: () -> Void) {
        let shouldResume = Self.lock.withLock {
            guard !settled else { return false }
            settled = true
            Self.live.remove(self)
            return true
        }
        if shouldResume { resume() }
    }
}
