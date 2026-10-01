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

// MARK: - realm links

/// This decides whether a link in rendered markdown stays inside the app or
/// leaves for the browser. Wrong either way is visible: too eager and every
/// external link dies, too shy and every post opens Safari on a URL with no host.
@Suite("realm links")
struct RealmLinkTests {
    private func subpath(_ text: String) -> String? {
        guard let url = URL(string: text) else { return nil }
        return GnoRealmLink.renderPath(of: url, in: "gno.land/r/moul/blog")
    }

    @Test func readsASubPageOfTheSameRealm() {
        #expect(subpath("/r/moul/blog:gnopm") == "gnopm")
        #expect(subpath("/r/moul/blog:t/tooling") == "t/tooling")
    }

    /// The separator is a colon. `/r/moul/blog/gnopm` is a different package,
    /// not a page of this one.
    @Test func aSlashIsNotTheSubPageSeparator() {
        #expect(subpath("/r/moul/blog/gnopm") == nil)
    }

    @Test func leavesOtherRealmsAndTheWebAlone() {
        #expect(subpath("/r/gnoland/blog:hello") == nil)
        #expect(subpath("https://github.com/moul") == nil)
        #expect(subpath("/r/moul/blog") == nil)
    }
}

/// Every page of the wiki and the registry is one of these, so the parser has to
/// get nested paths and namespaces right, not just the blog's one-segment slugs.
@Suite("realm links, deeper")
struct DeeperRealmLinkTests {
    @Test func keepsNamespacesAndQueriesInThePath() {
        let wiki = "gno.land/r/moul/x/wiki/v0"
        #expect(GnoRealmLink.renderPath(of: URL(string: "/r/moul/x/wiki/v0:Special:AllPages")!, in: wiki)
            == "Special:AllPages")
        #expect(GnoRealmLink.renderPath(of: URL(string: "/r/moul/x/wiki/v0:Special:Backlinks?page=Gno")!, in: wiki)
            == "Special:Backlinks?page=Gno")
    }

    @Test func keepsAPackagePathAsTheSubPage() {
        let url = URL(string: "/r/moul/gnopm/registry/v0:gno.land/p/moul/agents/commit/v0")!
        #expect(GnoRealmLink.renderPath(of: url, in: "gno.land/r/moul/gnopm/registry/v0")
            == "gno.land/p/moul/agents/commit/v0")
    }

    /// A txlink has no colon before its `$`, so it is never read as a page.
    @Test func aTxlinkIsNotAPage() {
        let url = URL(string: "/r/moul/x/wiki/v0$help&func=Edit&title=Gno")!
        #expect(GnoRealmLink.renderPath(of: url, in: "gno.land/r/moul/x/wiki/v0") == nil)
    }
}

/// The edit link on every article. Read wrong, the editor opens on a page that
/// does not exist and the save creates it.
@Suite("txlinks")
struct CallLinkTests {
    private let wiki = "gno.land/r/moul/x/wiki/v0"

    private func call(_ text: String) -> GnoRealmLink.Call? {
        guard let url = URL(string: text) else { return nil }
        return GnoRealmLink.call(of: url, in: wiki)
    }

    /// Verbatim from `Render("Gno")` on gnoland-1, 2026-10-01.
    @Test func readsTheEditLinkAnArticleRenders() {
        #expect(call("/r/moul/x/wiki/v0$help&func=Edit&title=Gno")
            == .init(function: "Edit", args: ["title": "Gno"]))
    }

    /// `url.Values.Encode` writes a space as `+` and a colon as `%3A`.
    @Test func decodesTheFormEncoding() {
        #expect(call("/r/moul/x/wiki/v0$help&func=Edit&title=Gno+land")?.args["title"] == "Gno land")
        #expect(call("/r/moul/x/wiki/v0$help&func=Edit&title=Category%3AA%26B")?.args["title"] == "Category:A&B")
    }

    @Test func survivesAMarkdownParserThatAddedAHost() {
        #expect(call("https://gno.land/r/moul/x/wiki/v0$help&func=Edit&title=Gno")?.args["title"] == "Gno")
    }

    @Test func ignoresOtherRealmsPagesAndBareHelp() {
        #expect(call("/r/moul/blog$help&func=Edit&title=Gno") == nil)
        #expect(call("/r/moul/x/wiki/v0:Gno") == nil)
        #expect(call("/r/moul/x/wiki/v0$help") == nil)
    }
}

/// What the editor starts from. Byte for byte, or the next revision silently
/// rewrites the page.
@Suite("wiki source")
struct WikiSourceTests {
    /// Verbatim from `Render("Gno/raw")` on gnoland-1, 2026-10-01. The hash is
    /// the chain's, not one computed here, so a parse that drops or adds a
    /// single newline fails `verified`.
    static let gno = "# Source of Gno (rev 2)\nsha256 `f671ee2a49ed67be197d22724bb38900672a080934a8253ec5722e8715c723a1`\n\n```\nGno is the language realms are written in: Go's syntax and semantics, minus the sources of non-determinism a chain cannot tolerate.\n\nSee [[Gno land]].\n\n[[Category:Languages]]\n\n```\n[← back to the article](/r/moul/x/wiki/v0:Gno)\n\n"

    @Test func readsBackWhatTheChainHashed() throws {
        let source = try #require(GnoWikiSource.parse(Self.gno))
        #expect(source.revision == 2)
        #expect(source.body.hasPrefix("Gno is the language"))
        #expect(source.body.hasSuffix("[[Category:Languages]]\n"))
        #expect(source.verified)
    }

    @Test func noticesABodyThatIsNotTheOneHashed() throws {
        let tampered = Self.gno.replacingOccurrences(of: "See [[Gno land]].", with: "See [[Gno]].")
        let source = try #require(GnoWikiSource.parse(tampered))
        #expect(!source.verified)
    }

    /// `CodeFence` outscans the body's backticks, so a body holding a
    /// three-backtick block comes back in a four-backtick fence, and the inner
    /// one must not end it.
    @Test func aLongerFenceKeepsAnInnerBlock() throws {
        let body = "before\n```go\nx := 1\n```\nafter"
        let markdown = "# Source of Code (rev 7)\nsha256 `\(GnoWikiSource.sha256(body))`\n\n````\n\(body)\n````\n"
        let source = try #require(GnoWikiSource.parse(markdown))
        #expect(source.body == body)
        #expect(source.revision == 7)
        #expect(source.verified)
    }

    /// A missing page renders an invitation to create it, which is not a source.
    @Test func aMissingPageIsNotASource() {
        #expect(GnoWikiSource.parse("# Nope\nThis page does not exist yet.\n") == nil)
        #expect(GnoWikiSource.parse("404: no revision") == nil)
    }
}
