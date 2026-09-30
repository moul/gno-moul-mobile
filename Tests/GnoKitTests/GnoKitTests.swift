import Foundation
import Testing
@testable import GnoKit

// MARK: - bech32

@Suite("bech32")
struct Bech32Tests {
    /// Ground truth from the library gno itself calls: tm2/pkg/bech32 wraps
    /// btcsuite's `ConvertBits(8,5,true)` + `Encode`, and these strings came out
    /// of that Go code for these exact bytes. A same-implementation test would
    /// only prove this file agrees with itself.
    @Test func matchesWhatGnoProduces() {
        #expect(Bech32.encode(hrp: "bc", data: Data()) == "bc1gmk9yu")
        #expect(Bech32.encode(hrp: "gpub", data: Data([1, 2, 3])) == "gpub1qypqx8hr369")
        #expect(Bech32.encode(hrp: "g", data: Data([1, 2, 3])) == "g1qypqxrchagl")
        #expect(
            Bech32.encode(hrp: "bc", data: Data([0x00, 0x14, 0x75, 0x1e, 0x76, 0xe8, 0x19, 0x91, 0x96, 0xd4,
                                                 0x54, 0x94, 0x1c, 0x45, 0xd1, 0xb3, 0xa3, 0x23, 0xf1, 0x43,
                                                 0x3b, 0xd6]))
                == "bc1qq2828nkaqver9k52j2pc3w3kw3j8u2r80tqukal5w"
        )
    }

    /// The shape that actually matters: an amino-marshaled secp256k1 key, which
    /// is what `KeyInfo.pub_key` carries and what `-pubkey` has to be handed.
    @Test func encodesAnAminoPubKey() {
        var amino = Data([0xeb, 0x5a, 0xe9, 0x87, 0x21])
        amino.append(contentsOf: (1...33).map(UInt8.init))
        #expect(
            Bech32.pubKey(amino)
                == "gpub1addwnpepqypqxpq9qcrsszg2pvxq6rs0zqg3yyc5z5tpwxqergd3c8g7ruszz4k07lu"
        )
    }

    /// The hrp is part of the checksum, so the same bytes under two prefixes
    /// must not differ only in their prefix.
    @Test func theHrpChangesTheChecksum() {
        let bytes = Data(repeating: 0xAB, count: 33)
        let asPubKey = Bech32.pubKey(bytes)
        let asAddress = Bech32.encode(hrp: "g", data: bytes)
        #expect(asPubKey.hasPrefix("gpub1"))
        #expect(asAddress.hasPrefix("g1"))
        #expect(String(asPubKey.dropFirst(5)) != String(asAddress.dropFirst(2)))
    }

    /// gno pins this prefix in tm2/pkg/crypto/globals.go, and
    /// `gnokey maketx session create -pubkey` will not take anything else.
    @Test func usesGnosPubKeyPrefix() {
        #expect(Bech32.pubKeyPrefix == "gpub")
    }
}

// MARK: - qeval

@Suite("qeval replies")
struct QEvalTests {
    @Test func readsASingleValue() {
        #expect(GnoQEval.scalar("(42 int)") == "42")
        #expect(GnoQEval.int("(42 int)") == 42)
    }

    /// The trap this parser exists for: the width of the type is not part of
    /// the number. "Strip everything that is not a digit" answers 764 here.
    @Test func doesNotGlueTheTypeWidthOntoTheValue() {
        #expect(GnoQEval.int("(7 int64)") == 7)
        #expect(GnoQEval.scalar("(1 gno.land/r/demo/boards.BoardID)") == "1")
    }

    @Test func keepsSpacesInsideAStringValue() {
        #expect(GnoQEval.scalar("(\"hello there\" string)") == "\"hello there\"")
    }

    @Test func readsEveryReturnedValue() {
        let values = GnoQEval.values("(1 int)\n(true bool)")
        #expect(values.count == 2)
        #expect(values.last == GnoQEval.Value(literal: "true", type: "bool"))
    }

    @Test func refusesWhatIsNotALiteral() {
        #expect(GnoQEval.scalar("") == nil)
        #expect(GnoQEval.scalar("boom") == nil)
    }
}

// MARK: - session scope

@Suite("session scope")
struct SessionScopeTests {
    private func session(allowing paths: [String]) throws -> GnoSessionAccount {
        let json = """
        {"base_account":{"address":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="},
         "master_address":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
         "allow_paths":\(try String(data: JSONEncoder().encode(paths), encoding: .utf8)!)}
        """
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(GnoSessionAccount.self, from: Data(json.utf8))
    }

    @Test func coversTheRealmItNames() throws {
        let grant = try session(allowing: ["vm/exec:gno.land/r/moul/home"])
        #expect(grant.covers(realm: "gno.land/r/moul/home"))
    }

    /// A trailing version digit is not a path segment. A grant on `counter`
    /// must not be read as covering `counter2`, or the app enables a button
    /// whose transaction the chain will refuse.
    @Test func aTrailingDigitIsNotAPathSegment() throws {
        let grant = try session(allowing: ["vm/exec:gno.land/r/moul/x/daily/counter"])
        #expect(grant.covers(realm: "gno.land/r/moul/x/daily/counter/v0"))
        #expect(!grant.covers(realm: "gno.land/r/moul/x/daily/counter2"))
    }

    @Test func starCoversEverything() throws {
        let grant = try session(allowing: ["*"])
        #expect(grant.covers(realm: "gno.land/r/gov/dao"))
    }

    /// An empty AllowPaths grants nothing. Reading it as unrestricted is the
    /// failure that opens a session up rather than closing it.
    @Test func noEntriesGrantNothing() throws {
        let grant = try session(allowing: [])
        #expect(!grant.covers(realm: "gno.land/r/moul/home"))
    }

    @Test func anEntryWithoutATypePrefixCoversNothing() throws {
        let grant = try session(allowing: ["gno.land/r/moul/home"])
        #expect(!grant.covers(realm: "gno.land/r/moul/home"))
    }
}

// MARK: - decoding

@Suite("reply decoding")
struct DecodingTests {
    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()

    /// Go writes these replies with `omitempty`, so a zero is not sent at all.
    /// A local key's `type` is 0, which means every single key would fail to
    /// decode if the field were required.
    @Test func absentZerosDecodeAsZero() throws {
        let json = #"{"name":"moul-app-session","address":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="}"#
        let key = try decoder.decode(GnoKeyInfo.self, from: Data(json.utf8))
        #expect(key.type == 0)
        #expect(key.pubKey.isEmpty)
        #expect(key.name == "moul-app-session")
    }

    /// Bytes cross as standard base64, which is JSONDecoder's default for Data.
    @Test func addressesDecodeFromBase64() throws {
        let json = #"{"address":"AQID"}"#
        struct Wrapper: Decodable { let address: GnoAddress }
        let wrapper = try decoder.decode(Wrapper.self, from: Data(json.utf8))
        #expect(wrapper.address.bytes == Data([1, 2, 3]))
    }

    @Test func feesKeepTheirNegativeStorageDelta() throws {
        let json = #"{"tx_json":"{}","gas_wanted":120000,"storage_delta":-512,"total_fee":{"denom":"ugnot","amount":9350}}"#
        let fees = try decoder.decode(GnoTxFees.self, from: Data(json.utf8))
        #expect(fees.gasWanted == 120_000)
        #expect(fees.storageDelta == -512)
        #expect(fees.totalFee?.amount == 9350)
    }

    @Test func aHashRendersAsUppercaseHex() throws {
        let json = #"{"hash":"AAECqw==","height":12}"#
        let result = try decoder.decode(GnoTxResult.self, from: Data(json.utf8))
        #expect(result.hashHex == "000102AB")
        #expect(result.height == 12)
    }
}

// MARK: - amounts

@Suite("amounts")
struct CoinTests {
    @Test func rendersWholeAndFractionalGnot() {
        #expect(GnoCoin.ugnot(5_000_000).display == "5 GNOT")
        #expect(GnoCoin.ugnot(12_500_000).display == "12.5 GNOT")
        #expect(GnoCoin.ugnot(9_350).display == "0.00935 GNOT")
        #expect(GnoCoin.ugnot(0).display == "0 GNOT")
    }

    /// A storage refund is reported as a negative delta, and the sign belongs
    /// in front of the whole number, not inside the fraction.
    @Test func rendersANegativeAmount() {
        #expect(GnoCoin.ugnot(-512_400).display == "-0.5124 GNOT")
        #expect(GnoCoin.ugnot(-2_000_000).display == "-2 GNOT")
    }

    @Test func leavesAnUnknownDenomAlone() {
        #expect(GnoCoin(denom: "ufoo", amount: 3).display == "3 ufoo")
    }
}

// MARK: - errors

@Suite("errors")
struct ErrorTests {
    /// The bridge can only hand the host a string, so the ErrCode travels in a
    /// JSON envelope behind a marker. Without parsing it the code survives only
    /// as text to pattern-match.
    @Test func recoversTheCodeFromTheEnvelope() {
        let payload = #"{"detail":{"code":211,"message":"out of gas"},"error":"invoke: out of gas","connectCode":2}"#
        let error = GnoError.from(NSError(
            domain: "test", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "gnonative-error:" + payload]
        ))
        #expect(error.code == .outOfGas)
        #expect(error.displayText == "out of gas")
    }

    /// A realm's panic text is written by whoever deployed it, so it is quoted
    /// rather than spoken as the app's own words.
    @Test func attributesWhatTheChainSaid() {
        let payload = #"{"detail":{"code":220,"message":"unauthorized caller"},"error":"x","connectCode":2}"#
        let error = GnoError.from(NSError(
            domain: "test", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "gnonative-error:" + payload]
        ))
        #expect(error.displayText.hasPrefix("The chain replied: "))
    }

    @Test func leavesAPlainRejectionAlone() {
        let error = GnoError.from(NSError(domain: "t", code: 1, userInfo: [NSLocalizedDescriptionKey: "boom"]))
        #expect(error.code == nil)
        #expect(error.displayText == "boom")
    }

    /// A finished stream rejects with a bare io.EOF and no envelope. Reading it
    /// as a failure turns every successful broadcast into an error.
    @Test func recognisesTheEndOfAStream() {
        let end = GnoError.from(NSError(domain: "t", code: 1, userInfo: [NSLocalizedDescriptionKey: "EOF"]))
        #expect(end.isStreamEnd)
        #expect(!GnoError.bridge("boom").isStreamEnd)
    }
}
