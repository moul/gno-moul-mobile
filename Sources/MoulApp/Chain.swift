import Foundation

/// Where the app talks, and as whom.
struct Chain: Hashable, Identifiable, Sendable {
    var id: String { chainID }
    let name: String
    let chainID: String
    let rpc: String
    /// The explorer that can show a transaction hash.
    let explorer: String
    /// The chain's consensus MaxGas, which is the ceiling a transaction carries
    /// while it is simulated. Read from `consensus_params` on 2026-09-30.
    let maxGas: Int64

    static let mainnet = Chain(
        name: "mainnet",
        chainID: "gnoland-1",
        rpc: "https://rpc.gno.land:443",
        explorer: "https://gnoscan.io/transactions/details?txhash=",
        maxGas: 3_000_000_000
    )

    static let all: [Chain] = [.mainnet]
}

enum Defaults {
    /// The master account the app acts for. A session signs, but the realm and
    /// the bank both see this address as the caller, so it is the identity the
    /// whole app is about.
    static let masterBech32 = "g1manfred47kzduec920z88wfr64ylksmdcedlf5"

    /// The local key name in the app's own keybase.
    static let sessionKeyName = "moul-app-session"

    /// 90 days, matching what `gnoagent session new` defaults to.
    static let sessionLifetime: TimeInterval = 90 * 24 * 60 * 60
}
