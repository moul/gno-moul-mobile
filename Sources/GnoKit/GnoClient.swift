import Foundation

/// The typed surface over the bridge.
///
/// Both directions of the wire are snake_case, which is the one thing that makes
/// this layer small: requests go through `protojson`, which accepts the original
/// proto field name, and replies come from Go's `encoding/json`, whose tags are
/// that same name. So one coder pair covers every call.
///
/// Go writes those replies with `omitempty`, so any field that can be zero is
/// simply absent. Every response type here treats absent as zero rather than as
/// an error.
public actor GnoClient {
    private let bridge: GnoBridge

    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return encoder
    }()

    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()

    /// The gas an unsigned transaction carries while it is being simulated.
    ///
    /// It cannot be 0: the chain answers `invalid gas wanted` and the estimate
    /// never happens. It must also not be a guess at the real cost, because the
    /// simulation is clipped by whatever it carries. gnokey solves this by
    /// raising it to the chain's consensus MaxGas before simulating, and so
    /// does this; `estimateFees(updateTx:)` writes the measured value back.
    public var simulationGasCeiling: Int64 = 3_000_000_000

    public init(bridge: GnoBridge = GnoBridge()) {
        self.bridge = bridge
    }

    public func setSimulationGasCeiling(_ gas: Int64) {
        simulationGasCeiling = gas
    }

    public func start(_ config: GnoBridge.Config = .standard()) async throws {
        try await bridge.start(config)
    }

    public func stop() async throws {
        try await bridge.stop()
    }

    // MARK: - Chain

    public func setRemote(_ remote: String) async throws {
        _ = try await call("SetRemote", Req.SetRemote(remote: remote), as: Empty.self)
    }

    public func remote() async throws -> String {
        try await call("GetRemote", Empty(), as: Res.GetRemote.self).remote
    }

    public func setChainID(_ chainID: String) async throws {
        _ = try await call("SetChainID", Req.SetChainID(chainId: chainID), as: Empty.self)
    }

    public func chainID() async throws -> String {
        try await call("GetChainID", Empty(), as: Res.GetChainID.self).chainId ?? ""
    }

    // MARK: - Reading a realm

    /// Calls a realm's `Render(path)`. The result is markdown.
    public func render(realm: String, path: String = "") async throws -> String {
        try await call("Render", Req.Render(packagePath: realm, args: path), as: Res.Render.self).result ?? ""
    }

    /// Evaluates a pure expression against a realm, without a transaction.
    /// The reply is a typed literal: `(42 int)`.
    public func qeval(realm: String, expression: String) async throws -> String {
        try await call(
            "QEval",
            Req.QEval(packagePath: realm, expression: expression),
            as: Res.QEval.self
        ).result ?? ""
    }

    public func account(_ address: GnoAddress) async throws -> GnoBaseAccount? {
        try await call("QueryAccount", Req.QueryAccount(address: address), as: Res.QueryAccount.self).accountInfo
    }

    /// Reads a live session grant.
    ///
    /// Both addresses are required and neither is optional: a session is not a
    /// plain account, so `auth/accounts/<session>` answers null, and only the
    /// master-scoped path returns anything at all.
    public func sessionAccount(master: GnoAddress, session: GnoAddress) async throws -> GnoSessionAccount? {
        try await call(
            "QuerySessionAccount",
            Req.QuerySessionAccount(masterAddress: master, sessionAddress: session),
            as: Res.QuerySessionAccount.self
        ).accountInfo
    }

    // MARK: - Keys

    public func generateRecoveryPhrase() async throws -> String {
        try await call("GenerateRecoveryPhrase", Empty(), as: Res.RecoveryPhrase.self).phrase
    }

    public func keys() async throws -> [GnoKeyInfo] {
        try await call("ListKeyInfo", Empty(), as: Res.ListKeyInfo.self).keys ?? []
    }

    public func hasKey(named name: String) async throws -> Bool {
        try await call("HasKeyByName", Req.Name(name: name), as: Res.Has.self).has ?? false
    }

    public func key(named name: String) async throws -> GnoKeyInfo {
        try await call("GetKeyInfoByName", Req.Name(name: name), as: Res.Key.self).key
    }

    @discardableResult
    public func createAccount(
        name: String,
        mnemonic: String,
        password: String,
        account: UInt32 = 0,
        index: UInt32 = 0
    ) async throws -> GnoKeyInfo {
        try await call(
            "CreateAccount",
            Req.CreateAccount(
                nameOrBech32: name,
                mnemonic: mnemonic,
                bip39Passwd: "",
                password: password,
                account: account,
                index: index
            ),
            as: Res.Key.self
        ).key
    }

    /// Makes a key the one that signs.
    ///
    /// `master` is what turns this into a session signer: without it the core
    /// signs as the key itself, which for a session key is an account the chain
    /// does not know.
    @discardableResult
    public func activate(name: String, master: GnoAddress? = nil) async throws -> GnoKeyInfo {
        try await call(
            "ActivateAccount",
            Req.Activate(nameOrBech32: name, master: master),
            as: Res.Activate.self
        ).key
    }

    public func setPassword(_ password: String, for address: GnoAddress) async throws {
        _ = try await call("SetPassword", Req.SetPassword(password: password, address: address), as: Empty.self)
    }

    public func deleteAccount(name: String, password: String) async throws {
        _ = try await call(
            "DeleteAccount",
            Req.DeleteAccount(nameOrBech32: name, password: password, skipPassword: false),
            as: Empty.self
        )
    }

    // MARK: - Addresses

    public func bech32(_ address: GnoAddress) async throws -> String {
        try await call("AddressToBech32", Req.AddressToBech32(address: address), as: Res.Bech32.self).bech32Address
    }

    /// Decodes a `gpub…` key. The core owns this direction; `Bech32.pubKey`
    /// owns the other one, and `CoreIntegrationTests` checks the two agree.
    public func pubKeyBytes(fromBech32 bech32: String) async throws -> Data {
        try await call(
            "PubKeyBytesFromBech32",
            Req.PubKeyFromBech32(bech32PubKey: bech32),
            as: Res.PubKeyBytes.self
        ).pubKeyBytes
    }

    public func address(fromBech32 bech32: String) async throws -> GnoAddress {
        try await call(
            "AddressFromBech32",
            Req.AddressFromBech32(bech32Address: bech32),
            as: Res.AddressBytes.self
        ).address
    }

    // MARK: - Writing

    /// Builds an unsigned call transaction.
    ///
    /// `caller` is the **master** address when a session will sign it: the
    /// transaction is the master's, the session only holds the pen.
    public func makeCallTx(caller: GnoAddress, msgs: [GnoMsgCall], memo: String = "") async throws -> String {
        try await call(
            "MakeCallTx",
            Req.MakeCallTx(
                gasFee: "1ugnot",
                gasWanted: simulationGasCeiling,
                memo: memo,
                callerAddress: caller,
                msgs: msgs
            ),
            as: Res.MakeTx.self
        ).txJson
    }

    /// Builds an unsigned `CreateSession` transaction. Only the master can sign it.
    public func makeCreateSessionTx(
        creator: GnoAddress,
        msgs: [GnoMsgCreateSession],
        memo: String = ""
    ) async throws -> String {
        try await call(
            "MakeCreateSessionTx",
            Req.CreateSessionTx(
                gasFee: "1ugnot",
                gasWanted: simulationGasCeiling,
                memo: memo,
                creatorAddress: creator,
                msgs: msgs
            ),
            as: Res.MakeTx.self
        ).txJson
    }

    /// Simulates the transaction and returns what it will actually cost.
    ///
    /// The margins are hundredths: 10000 is 100.00%, so the defaults add 20% to
    /// the gas and 10% to the price. `updateTx` writes the sized gas back into
    /// the returned transaction, which is the copy that must be signed.
    public func estimateFees(
        txJson: String,
        signer: GnoAddress,
        gasMargin: UInt32 = 12000,
        priceMargin: UInt32 = 11000
    ) async throws -> GnoTxFees {
        try await call(
            "EstimateTxFees",
            Req.EstimateTxFees(
                txJson: txJson,
                address: signer,
                gasSecurityMargin: gasMargin,
                gasPriceSecurityMargin: priceMargin,
                updateTx: true
            ),
            as: GnoTxFees.self
        )
    }

    /// Signs with the activated account. Zero account/sequence means "ask the chain".
    public func sign(txJson: String, signer: GnoAddress) async throws -> String {
        try await call(
            "SignTx",
            Req.SignTx(txJson: txJson, address: signer, accountNumber: 0, sequenceNumber: 0),
            as: Res.SignTx.self
        ).signedTxJson
    }

    /// Broadcasts and waits for the commit. Irreversible.
    public func broadcast(signedTxJson: String) async throws -> GnoTxResult {
        try await stream(
            "BroadcastTxCommit",
            Req.Broadcast(signedTxJson: signedTxJson),
            as: GnoTxResult.self
        )
    }

    /// The whole write path in one step: build, size from a simulation, sign,
    /// broadcast. Returns the cost alongside the receipt so a caller can show
    /// what it just spent.
    ///
    /// Nothing here hands the chain a gas number that did not come from
    /// `EstimateTxFees`.
    @discardableResult
    public func send(
        caller: GnoAddress,
        signer: GnoAddress,
        msgs: [GnoMsgCall],
        memo: String = ""
    ) async throws -> (result: GnoTxResult, fees: GnoTxFees) {
        let unsigned = try await makeCallTx(caller: caller, msgs: msgs, memo: memo)
        let fees = try await estimateFees(txJson: unsigned, signer: signer)
        let signed = try await sign(txJson: fees.txJson, signer: signer)
        let result = try await broadcast(signedTxJson: signed)
        return (result, fees)
    }

    // MARK: - Plumbing

    /// Reaches the bridge with no typing at all. Only the tests use it, to
    /// exercise the failure path a wrong method name takes.
    func callForTests(_ method: String) async throws -> Data {
        try await bridge.invoke(method, json: "{}")
    }

    private func call<Request: Encodable, Response: Decodable>(
        _ method: String,
        _ request: Request,
        as: Response.Type
    ) async throws -> Response {
        let payload = try encoder.encode(request)
        guard let json = String(data: payload, encoding: .utf8) else {
            throw GnoError.decoding("request for \(method) was not utf8")
        }
        let reply = try await bridge.invoke(method, json: json)
        do {
            return try decoder.decode(Response.self, from: reply)
        } catch {
            throw GnoError.decoding("\(method): \(error)")
        }
    }

    /// Runs a streaming method and returns its last message.
    ///
    /// Every streaming call in this API reports progress and then one final
    /// outcome, so the last message is the answer. A caller that wants the
    /// intermediate ones should open the stream itself.
    private func stream<Request: Encodable, Response: Decodable>(
        _ method: String,
        _ request: Request,
        as: Response.Type
    ) async throws -> Response {
        let payload = try encoder.encode(request)
        guard let json = String(data: payload, encoding: .utf8) else {
            throw GnoError.decoding("request for \(method) was not utf8")
        }
        let id = try await bridge.openStream(method, json: json)
        defer { Task { await bridge.closeStream(id) } }

        var last: Response?
        while let message = try await bridge.receive(stream: id) {
            do {
                last = try decoder.decode(Response.self, from: message)
            } catch {
                throw GnoError.decoding("\(method): \(error)")
            }
        }
        guard let last else {
            throw GnoError.decoding("\(method) closed without sending a result")
        }
        return last
    }
}

// MARK: - Wire shapes

struct Empty: Codable {}

/// Request bodies. Field names match the proto, which `protojson` accepts
/// alongside its own camelCase form.
enum Req {
    struct SetRemote: Encodable { let remote: String }
    struct SetChainID: Encodable { let chainId: String }
    struct Name: Encodable { let name: String }
    struct Render: Encodable { let packagePath: String; let args: String }
    struct QEval: Encodable { let packagePath: String; let expression: String }
    struct QueryAccount: Encodable { let address: GnoAddress }
    struct QuerySessionAccount: Encodable { let masterAddress: GnoAddress; let sessionAddress: GnoAddress }
    struct CreateAccount: Encodable {
        let nameOrBech32: String
        let mnemonic: String
        let bip39Passwd: String
        let password: String
        let account: UInt32
        let index: UInt32
    }
    struct Activate: Encodable { let nameOrBech32: String; let master: GnoAddress? }
    struct SetPassword: Encodable { let password: String; let address: GnoAddress }
    struct DeleteAccount: Encodable { let nameOrBech32: String; let password: String; let skipPassword: Bool }
    struct AddressToBech32: Encodable { let address: GnoAddress }
    struct AddressFromBech32: Encodable { let bech32Address: String }
    struct PubKeyFromBech32: Encodable { let bech32PubKey: String }
    struct MakeCallTx: Encodable {
        let gasFee: String
        let gasWanted: Int64
        let memo: String
        let callerAddress: GnoAddress
        let msgs: [GnoMsgCall]
    }
    struct CreateSessionTx: Encodable {
        let gasFee: String
        let gasWanted: Int64
        let memo: String
        let creatorAddress: GnoAddress
        let msgs: [GnoMsgCreateSession]
    }
    struct EstimateTxFees: Encodable {
        let txJson: String
        let address: GnoAddress
        let gasSecurityMargin: UInt32
        let gasPriceSecurityMargin: UInt32
        let updateTx: Bool
    }
    struct SignTx: Encodable {
        let txJson: String
        let address: GnoAddress
        let accountNumber: UInt64
        let sequenceNumber: UInt64
    }
    struct Broadcast: Encodable { let signedTxJson: String }
}

/// Reply bodies. Go's `omitempty` drops every zero, so anything that can be zero
/// is optional here.
enum Res {
    struct GetRemote: Decodable { let remote: String }
    struct GetChainID: Decodable { let chainId: String? }
    struct Render: Decodable { let result: String? }
    struct QEval: Decodable { let result: String? }
    struct QueryAccount: Decodable { let accountInfo: GnoBaseAccount? }
    struct QuerySessionAccount: Decodable { let accountInfo: GnoSessionAccount? }
    struct RecoveryPhrase: Decodable { let phrase: String }
    struct ListKeyInfo: Decodable { let keys: [GnoKeyInfo]? }
    struct Has: Decodable { let has: Bool? }
    struct Key: Decodable { let key: GnoKeyInfo }
    struct Activate: Decodable { let key: GnoKeyInfo; let hasPassword: Bool? }
    struct Bech32: Decodable { let bech32Address: String }
    struct AddressBytes: Decodable { let address: GnoAddress }
    struct PubKeyBytes: Decodable { let pubKeyBytes: Data }
    struct MakeTx: Decodable { let txJson: String }
    struct SignTx: Decodable { let signedTxJson: String }
}
