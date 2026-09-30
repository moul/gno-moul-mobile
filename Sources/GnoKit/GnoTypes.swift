import Foundation

/// A gno account address, in its wire form.
///
/// The core speaks raw bytes; people read bech32. Converting between the two is
/// `GnoClient.bech32(...)` / `.address(fromBech32:)`, because the hrp and the
/// checksum belong to the core, not to a hand-rolled Swift bech32.
public struct GnoAddress: Hashable, Sendable, Codable {
    public let bytes: Data

    public init(_ bytes: Data) { self.bytes = bytes }

    public init(from decoder: Decoder) throws {
        bytes = try decoder.singleValueContainer().decode(Data.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(bytes)
    }
}

public struct GnoCoin: Codable, Hashable, Sendable {
    public var denom: String
    public var amount: Int64

    public init(denom: String = "ugnot", amount: Int64) {
        self.denom = denom
        self.amount = amount
    }

    public static func ugnot(_ amount: Int64) -> GnoCoin { GnoCoin(denom: "ugnot", amount: amount) }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        denom = try container.decodeIfPresent(String.self, forKey: .denom) ?? "ugnot"
        amount = try container.decodeIfPresent(Int64.self, forKey: .amount) ?? 0
    }

    /// "12.5 GNOT" for 12_500_000 ugnot; whole numbers lose the decimals.
    ///
    /// The sign goes in front of the whole number, not inside the fraction: a
    /// storage refund arrives as a negative amount, and integer division puts
    /// -512400 ugnot in the -1 < x < 0 band where the quotient is 0 and the sign
    /// would vanish.
    public var display: String {
        guard denom == "ugnot" else { return "\(amount) \(denom)" }
        let sign = amount < 0 ? "-" : ""
        let magnitude = abs(amount)
        let whole = magnitude / 1_000_000
        let fraction = magnitude % 1_000_000
        if fraction == 0 { return "\(sign)\(whole) GNOT" }
        let text = String(format: "%06d", fraction)
            .replacingOccurrences(of: "0+$", with: "", options: .regularExpression)
        return "\(sign)\(whole).\(text) GNOT"
    }
}

public struct GnoKeyInfo: Codable, Hashable, Sendable {
    /// 0 local, 1 ledger, 2 offline, 3 multi.
    public var type: UInt32
    public var name: String
    public var pubKey: Data
    public var address: GnoAddress

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decodeIfPresent(UInt32.self, forKey: .type) ?? 0
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        pubKey = try container.decodeIfPresent(Data.self, forKey: .pubKey) ?? Data()
        address = try container.decode(GnoAddress.self, forKey: .address)
    }
}

public struct GnoBaseAccount: Codable, Sendable {
    public var address: GnoAddress
    public var coins: [GnoCoin]?
    public var pubKey: Data?
    public var accountNumber: UInt64?
    public var sequence: UInt64?

    public var balance: GnoCoin {
        coins?.first { $0.denom == "ugnot" } ?? .ugnot(0)
    }
}

/// What the chain knows about a live session grant.
///
/// A session address answers nothing on its own: `auth/accounts/<session>`
/// returns null, because a session is not a plain account. Only the
/// master-scoped query answers, which is why `GnoClient.sessionAccount` takes
/// both addresses.
public struct GnoSessionAccount: Codable, Sendable {
    public var baseAccount: GnoBaseAccount
    public var masterAddress: GnoAddress
    /// Unix seconds; 0 means no expiry.
    public var expiresAt: Int64?
    /// Empty means no spending at all, not unrestricted.
    public var spendLimit: [GnoCoin]?
    /// Seconds; 0 is a lifetime cap with no reset.
    public var spendPeriod: Int64?
    public var spendUsed: [GnoCoin]?
    public var spendReset: Int64?
    public var allowPaths: [String]?

    public var expiry: Date? {
        guard let expiresAt, expiresAt != 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(expiresAt))
    }

    public var limit: GnoCoin? { spendLimit?.first { $0.denom == "ugnot" } }
    public var used: GnoCoin { spendUsed?.first { $0.denom == "ugnot" } ?? .ugnot(0) }

    /// Fraction of the cap already spent, or nil when there is no cap.
    public var budgetUsedFraction: Double? {
        guard let limit, limit.amount > 0 else { return nil }
        return min(1, Double(used.amount) / Double(limit.amount))
    }

    /// Whether the grant covers a realm this app wants to call.
    ///
    /// The grammar is `<route>/<type>[:<path>]`, and a trailing version digit is
    /// not a path segment: a grant on `.../counter` does not cover
    /// `.../counter2`. This matches on the full path or on a `/`-terminated
    /// prefix so it never reports the wrong answer in that direction.
    public func covers(realm: String) -> Bool {
        guard let allowPaths else { return false }
        return allowPaths.contains { entry in
            if entry == "*" { return true }
            guard let colon = entry.firstIndex(of: ":") else { return false }
            let path = String(entry[entry.index(after: colon)...])
            return realm == path || realm.hasPrefix(path + "/")
        }
    }
}

/// One realm call inside a transaction.
public struct GnoMsgCall: Codable, Sendable {
    public var packagePath: String
    public var fnc: String
    public var args: [String]
    public var send: [GnoCoin]?
    /// An omitted max deposit is a 100 GNOT ceiling, not an opt-out.
    public var maxDeposit: [GnoCoin]?

    public init(
        packagePath: String,
        fnc: String,
        args: [String] = [],
        send: [GnoCoin]? = nil,
        maxDeposit: [GnoCoin]? = nil
    ) {
        self.packagePath = packagePath
        self.fnc = fnc
        self.args = args
        self.send = send
        self.maxDeposit = maxDeposit
    }
}

/// One session grant inside a `CreateSession` transaction.
public struct GnoMsgCreateSession: Codable, Sendable {
    /// The full session public key, not its address.
    public var sessionKey: Data
    /// Unix seconds; 0 means no expiry.
    public var expiresAt: Int64
    /// `"*"` or `<route>/<type>[:<path>]`. Required: an empty list grants nothing.
    public var allowPaths: [String]
    /// Empty means no spending is allowed, which fails closed.
    public var spendLimit: [GnoCoin]
    /// Seconds; 0 is a lifetime cap.
    public var spendPeriod: Int64

    public init(
        sessionKey: Data,
        expiresAt: Int64,
        allowPaths: [String],
        spendLimit: [GnoCoin],
        spendPeriod: Int64
    ) {
        self.sessionKey = sessionKey
        self.expiresAt = expiresAt
        self.allowPaths = allowPaths
        self.spendLimit = spendLimit
        self.spendPeriod = spendPeriod
    }
}

/// What a transaction will actually cost, as the chain reports it.
///
/// Every field here comes from a simulation. Nothing in this app writes a gas
/// number by hand.
public struct GnoTxFees: Codable, Sendable {
    public var txJson: String
    public var gasWanted: Int64
    public var gasFee: GnoCoin?
    /// Bytes the transaction adds, negative when it frees storage.
    public var storageDelta: Int64?
    public var storageFee: [GnoCoin]?
    public var totalFee: GnoCoin?

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        txJson = try container.decodeIfPresent(String.self, forKey: .txJson) ?? ""
        gasWanted = try container.decodeIfPresent(Int64.self, forKey: .gasWanted) ?? 0
        gasFee = try container.decodeIfPresent(GnoCoin.self, forKey: .gasFee)
        storageDelta = try container.decodeIfPresent(Int64.self, forKey: .storageDelta)
        storageFee = try container.decodeIfPresent([GnoCoin].self, forKey: .storageFee)
        totalFee = try container.decodeIfPresent(GnoCoin.self, forKey: .totalFee)
    }
}

/// The outcome of a broadcast.
public struct GnoTxResult: Codable, Sendable {
    public var result: Data?
    public var hash: Data?
    public var height: Int64?

    /// The hash as explorers spell it: uppercase hex.
    public var hashHex: String? {
        hash.map { $0.map { String(format: "%02X", $0) }.joined() }
    }
}
