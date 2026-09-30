import Foundation
import Testing
@testable import GnoKit

/// Tests that run the real Go core in-process.
///
/// They start a bridge, so they are slower than the rest and they touch the
/// filesystem. None of them talks to a chain: everything here is local, which
/// keeps them deterministic and runnable offline.
@Suite("gno core", .serialized)
struct CoreIntegrationTests {
    private func startedClient() async throws -> GnoClient {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("gnokit-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let client = GnoClient()
        try await client.start(GnoBridge.Config(rootDir: root.path, tmpDir: root.path))
        return client
    }

    @Test func startsAndAnswers() async throws {
        let client = try await startedClient()
        try await client.setRemote("https://rpc.gno.land:443")
        #expect(try await client.remote() == "https://rpc.gno.land:443")
        try await client.setChainID("gnoland-1")
        #expect(try await client.chainID() == "gnoland-1")
        try await client.stop()
    }

    /// The claim this whole file exists for.
    ///
    /// `Bech32.encode` is the one piece of gno's wire format written in Swift
    /// rather than called through the core, and `gnokey maketx session create
    /// -pubkey` will refuse anything it gets wrong. Encoding with Swift and
    /// decoding with the core's own `crypto.PubKeyFromBech32` is the only check
    /// that cannot agree with itself by construction.
    @Test func swiftBech32RoundTripsThroughTheCore() async throws {
        let client = try await startedClient()
        let mnemonic = try await client.generateRecoveryPhrase()
        let key = try await client.createAccount(name: "roundtrip", mnemonic: mnemonic, password: "test")

        let encoded = Bech32.pubKey(key.pubKey)
        #expect(encoded.hasPrefix("gpub1"))

        let decoded = try await client.pubKeyBytes(fromBech32: encoded)
        #expect(decoded == key.pubKey)

        try await client.stop()
    }

    /// A fresh mnemonic has to produce a fresh key, or the app would hand every
    /// device the same session address.
    @Test func mintsADistinctKeyEachTime() async throws {
        let client = try await startedClient()
        let first = try await client.createAccount(
            name: "one", mnemonic: client.generateRecoveryPhrase(), password: "test"
        )
        let second = try await client.createAccount(
            name: "two", mnemonic: client.generateRecoveryPhrase(), password: "test"
        )
        #expect(first.address != second.address)
        #expect(try await client.keys().count == 2)
        try await client.stop()
    }

    /// The bridge rejects a method name it cannot resolve, rather than hanging
    /// or returning something empty. `invoke` is reflection all the way down, so
    /// a typo has to be loud.
    @Test func refusesAnUnknownMethod() async throws {
        let client = try await startedClient()
        await #expect(throws: GnoError.self) {
            try await client.probeUnknownMethod()
        }
        try await client.stop()
    }
}

extension GnoClient {
    /// Test-only: exercises the bridge's own error path.
    func probeUnknownMethod() async throws {
        _ = try await callForTests("ThisMethodDoesNotExist")
    }
}
