import Foundation

/// The classified failures the core reports.
///
/// Mirrors `ErrCode` in `api/rpc.proto`. Only the codes this app can act on are
/// named; anything else arrives as `.other`, which is why the raw value is kept.
public enum GnoErrCode: Int, Sendable {
    case undefined = 0
    case notImplemented = 2
    case internalError = 3

    case invalidInput = 100
    case keyNameExists = 107
    case remoteUnreachable = 108
    case cryptoKeyNotFound = 151
    case noActiveAccount = 152
    case decryptionFailed = 154

    case unauthorized = 202
    case insufficientFunds = 203
    case unknownRequest = 204
    case unknownAddress = 206
    case insufficientCoins = 208
    case outOfGas = 211
    case insufficientFee = 213
    case invalidPkgPath = 217

    /// The chain refused for a reason it did not classify, typically a realm
    /// panic degraded to a string. The message is written by whoever deployed
    /// the realm, so it is untrusted: show it attributed and truncated.
    case chainRejected = 220
}

public enum GnoError: Error, Sendable {
    /// A call was made before `GnoBridge.start()`.
    case notStarted
    /// The bridge itself failed, with no code from the chain.
    case bridge(String)
    /// The core classified the failure.
    case core(code: GnoErrCode?, rawCode: Int, message: String, underlying: String)
    /// The reply did not decode into the expected shape.
    case decoding(String)

    public var code: GnoErrCode? {
        if case let .core(code, _, _, _) = self { return code }
        return nil
    }

    /// True for the "no more messages" rejection a finished stream produces.
    /// `StreamClientReceive` returns a bare `io.EOF`, so this is the whole
    /// signal: there is no envelope and no code behind it.
    var isStreamEnd: Bool {
        if case let .bridge(message) = self { return message == "EOF" }
        return false
    }

    /// Text safe to put in front of a person.
    ///
    /// `chainRejected` is quoted rather than spoken, because its wording belongs
    /// to a realm this app did not deploy, and is unbounded.
    public var displayText: String {
        switch self {
        case .notStarted:
            return "The gno core is not running yet."
        case let .bridge(message):
            return message
        case let .core(code, _, message, underlying):
            let text = message.isEmpty ? underlying : message
            if code == .chainRejected {
                return "The chain replied: \(text.prefix(240))"
            }
            return text
        case let .decoding(message):
            return "Unexpected reply from the gno core: \(message)"
        }
    }

    private static let envelopePrefix = "gnonative-error:"

    /// Recovers the structured detail the Go side packs into the rejection text.
    ///
    /// The bridge can only hand the host a string, so `bridge_error.go` prefixes
    /// a JSON envelope. Without this the `ErrCode` survives only as the
    /// "ErrOutOfGas(#211)" text `ErrCode.Error()` renders, which is a string to
    /// pattern-match rather than a value to switch on.
    static func from(_ error: NSError) -> GnoError {
        let text = error.localizedDescription
        guard text.hasPrefix(envelopePrefix) else { return .bridge(text) }

        let payload = String(text.dropFirst(envelopePrefix.count))
        guard let data = payload.data(using: .utf8),
              let envelope = try? JSONDecoder().decode(Envelope.self, from: data)
        else {
            return .bridge(text)
        }

        return .core(
            code: GnoErrCode(rawValue: envelope.detail.code),
            rawCode: envelope.detail.code,
            message: envelope.detail.message,
            underlying: envelope.error
        )
    }

    private struct Envelope: Decodable {
        struct Detail: Decodable {
            let code: Int
            let message: String
        }
        let detail: Detail
        let error: String
        let connectCode: Int
    }
}
