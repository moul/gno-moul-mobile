import Foundation
import GnoKit
import Observation

/// The app's whole state, and the onboarding it walks through to get there.
@MainActor
@Observable
final class AppModel {
    enum Stage: Equatable {
        /// Starting the core and resolving the master address.
        case starting
        /// A local session key exists; the chain has not been asked to trust it yet.
        case awaitingGrant
        /// The chain confirmed the grant and the key is activated.
        case ready
        case failed(String)
    }

    let client = GnoClient()
    var chain: Chain = .mainnet
    private(set) var stage: Stage = .starting

    /// The account the app acts for. A session signs, but this is the caller
    /// every realm and the bank will see.
    var masterBech32: String = Defaults.masterBech32
    private(set) var master: GnoAddress?

    /// The session key this device minted.
    private(set) var sessionKey: GnoKeyInfo?
    private(set) var sessionBech32: String = ""
    private(set) var sessionPubKeyBech32: String = ""

    /// What the chain says about the grant, refreshed on demand.
    private(set) var grant: GnoSessionAccount?

    /// The scope the app is asking for, derived from the features that write.
    let requestedPaths = Features.allowPaths
    let requestedBudget = Features.budget
    private(set) var expiresAt: Int64 = 0

    private var pollTask: Task<Void, Never>?

    // MARK: - Derived

    var isReady: Bool { stage == .ready }

    /// Features whose realm the live grant does not cover.
    ///
    /// This is not a cosmetic warning. A grant cannot be widened after the fact,
    /// so a feature added after the ceremony stays unusable until a new session
    /// is created, and the app has to say so rather than fail at broadcast time.
    var uncoveredFeatures: [FeatureDescriptor] {
        guard let grant else { return Features.all.filter(\.descriptor.writes).map(\.descriptor) }
        return Features.all
            .map(\.descriptor)
            .filter { $0.writes && !grant.covers(realm: $0.realm) }
    }

    // MARK: - Lifecycle

    func start() async {
        stage = .starting
        do {
            try await client.start()
            try await client.setRemote(chain.rpc)
            try await client.setChainID(chain.chainID)
            await client.setSimulationGasCeiling(chain.maxGas)

            let master = try await client.address(fromBech32: masterBech32)
            self.master = master

            try await loadOrMintSessionKey()
            await refreshGrant()
        } catch let error as GnoError {
            stage = .failed(error.displayText)
        } catch {
            stage = .failed(error.localizedDescription)
        }
    }

    /// Finds the device's session key, or mints one.
    ///
    /// The mnemonic is generated, used once and dropped: this key is not meant
    /// to be recovered anywhere else. Losing the phone should end the session,
    /// which is the entire argument for granting one instead of carrying a
    /// master key around.
    private func loadOrMintSessionKey() async throws {
        let name = Defaults.sessionKeyName

        if try await client.hasKey(named: name), Keychain.password(account: name) != nil {
            try await adopt(key: client.key(named: name))
            return
        }

        // A half-created key (keybase entry without its password, or the
        // reverse) cannot be used or recovered. Clear both sides and mint again.
        if try await client.hasKey(named: name), let stale = Keychain.password(account: name) {
            try? await client.deleteAccount(name: name, password: stale)
        }
        Keychain.remove(account: name)

        let password = Keychain.generated()
        let mnemonic = try await client.generateRecoveryPhrase()
        let key = try await client.createAccount(name: name, mnemonic: mnemonic, password: password)
        guard Keychain.store(password, account: name) else {
            try? await client.deleteAccount(name: name, password: password)
            throw GnoError.bridge("could not store the keybase password in the keychain")
        }
        try await adopt(key: key)
    }

    private func adopt(key: GnoKeyInfo) async throws {
        sessionKey = key
        sessionBech32 = try await client.bech32(key.address)
        sessionPubKeyBech32 = Bech32.pubKey(key.pubKey)
        expiresAt = Int64(Date().addingTimeInterval(Defaults.sessionLifetime).timeIntervalSince1970)

        // Activate it as itself, without a master. Nothing can be signed with it
        // yet, but the core reads the signer's pubkey from the *activated*
        // account, and a simulation needs one: without this every estimate
        // answers ErrNoActiveAccount rather than a gas number.
        // `refreshGrant` re-activates it with the master once the grant lands,
        // which is what turns it into a session signer.
        let activated = try await client.activate(name: Defaults.sessionKeyName)
        if let password = Keychain.password(account: Defaults.sessionKeyName) {
            try? await client.setPassword(password, for: activated.address)
        }
    }

    // MARK: - The grant

    /// Asks the chain whether the grant is live, and activates the key if it is.
    @discardableResult
    func refreshGrant() async -> Bool {
        guard let master, let sessionKey else { return false }
        do {
            let account = try await client.sessionAccount(master: master, session: sessionKey.address)
            grant = account
            if account != nil {
                // `master` is what makes this a session signer. Without it the
                // core signs as the key itself, an account the chain does not know.
                try await client.activate(name: Defaults.sessionKeyName, master: master)
                stage = .ready
                stopPolling()
                return true
            }
            stage = .awaitingGrant
            return false
        } catch let error as GnoError {
            // An absent grant is the expected state before the ceremony, not a
            // failure to show. Anything else is.
            if error.code == .unknownAddress || error.code == .noActiveAccount {
                stage = .awaitingGrant
                return false
            }
            stage = .failed(error.displayText)
            return false
        } catch {
            stage = .failed(error.localizedDescription)
            return false
        }
    }

    /// Watches for the grant while the handoff screen is open.
    func startPolling(every seconds: UInt64 = 5) {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if await self.refreshGrant() { return }
                try? await Task.sleep(for: .seconds(seconds))
            }
        }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// The one command only moul can run: the chain denies every `auth/*`
    /// message to a session, so no key this app holds can grant itself anything.
    ///
    /// It comes in two steps, and that is not laziness about gas. The app cannot
    /// size this transaction itself: simulating it needs the signature slot to
    /// carry the *master's* pubkey, and the master is deliberately not in this
    /// app's keybase. Handing the chain the session's own key instead is refused
    /// with `ErrUnauthorized(#202)`, measured against mainnet on 2026-09-30. So
    /// the first command measures and broadcasts nothing, and the second one
    /// carries what it printed.
    ///
    /// Everything the app *does* sign is sized from a simulation, because there
    /// the signer is the session key it holds. This is the one transaction it
    /// does not sign.
    var grantCommandMeasure: String {
        command(tail: "  -broadcast -simulate only")
    }

    var grantCommandBroadcast: String {
        command(tail: "  -gas-wanted <from step 1> -gas-fee <from step 1>ugnot \\\n  -broadcast")
    }

    private func command(tail: String) -> String {
        let allow = requestedPaths.map { "  -allow-paths \($0) \\" }.joined(separator: "\n")
        return """
        gnokey maketx session create moul \\
          -pubkey \(sessionPubKeyBech32) \\
        \(allow)
          -spend-limit \(requestedBudget)ugnot \\
          -spend-period 0 \\
          -expires-at \(expiresAt) \\
        \(tail) -chainid \(chain.chainID) -remote \(chain.rpc)
        """
    }

    /// Ends the app's own half of the session. The grant stays live on chain
    /// until moul revokes it, which this app cannot do for the same reason it
    /// cannot create one.
    func forgetSessionKey() async {
        stopPolling()
        if let password = Keychain.password(account: Defaults.sessionKeyName) {
            try? await client.deleteAccount(name: Defaults.sessionKeyName, password: password)
        }
        Keychain.remove(account: Defaults.sessionKeyName)
        sessionKey = nil
        sessionBech32 = ""
        sessionPubKeyBech32 = ""
        grant = nil
        stage = .starting
    }

    // MARK: - Calling a realm

    /// Reads a realm's `Render`.
    func render(_ realm: String, path: String = "") async throws -> String {
        try await client.render(realm: realm, path: path)
    }

    /// Evaluates an expression against a realm, with no transaction.
    func eval(_ realm: String, _ expression: String) async throws -> String {
        try await client.qeval(realm: realm, expression: expression)
    }

    /// Signs a call with the session and broadcasts it.
    ///
    /// The caller is the master and the signer is the session: that asymmetry is
    /// the whole mechanism. Gas comes from a simulation, never from a constant.
    @discardableResult
    func call(_ realm: String, _ function: String, args: [String] = []) async throws
        -> (result: GnoTxResult, fees: GnoTxFees)
    {
        guard let master, let sessionKey else { throw GnoError.notStarted }
        return try await client.send(
            caller: master,
            signer: sessionKey.address,
            msgs: [GnoMsgCall(packagePath: realm, fnc: function, args: args)]
        )
    }
}
