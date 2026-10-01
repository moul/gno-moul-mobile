import CryptoKit
import Foundation

/// A wiki page's source, read back from its `Title/raw` view.
///
/// Editing has to start from the bytes on chain, not from the rendered article:
/// the article has its `[[links]]` already expanded into markdown links, so
/// saving what the reader sees would rewrite every link on the page.
///
/// The raw view is markdown too: a heading carrying the revision, a line with
/// the body's sha256, and the body in a fenced code block. The fence is sized
/// to outscan any backtick run in the body, so the first line equal to the
/// opening fence is the closing one. The hash is the check that this parse got
/// the body back byte for byte, which matters because whatever the editor
/// starts from is what the next revision is diffed against.
public struct GnoWikiSource: Equatable, Sendable {
    public let revision: Int
    public let hash: String
    public let body: String

    /// True when the body hashes to what the realm printed next to it.
    public var verified: Bool { Self.sha256(body) == hash }

    /// The source in a `Title/raw` render, or nil when the reply is anything
    /// else: a missing page renders an invitation to create it, not a source.
    public static func parse(_ markdown: String) -> GnoWikiSource? {
        let lines = markdown.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let heading = lines.first, heading.hasPrefix("# Source of "),
              let revision = revisionNumber(in: heading),
              let hash = lines.lazy.compactMap(sha256Hex(in:)).first,
              let open = lines.firstIndex(where: isFence)
        else { return nil }

        let fence = lines[open]
        guard let close = lines[(open + 1)...].firstIndex(of: fence) else { return nil }
        let body = lines[(open + 1)..<close].joined(separator: "\n")
        return GnoWikiSource(revision: revision, hash: hash, body: body)
    }

    static func sha256(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func isFence(_ line: String) -> Bool {
        line.count >= 3 && line.allSatisfy { $0 == "`" }
    }

    /// `# Source of Gno (rev 2)` → 2.
    private static func revisionNumber(in heading: String) -> Int? {
        guard let open = heading.range(of: "(rev ", options: .backwards),
              heading.hasSuffix(")")
        else { return nil }
        return Int(heading[open.upperBound..<heading.index(before: heading.endIndex)])
    }

    /// ``sha256 `f671…` `` → `f671…`.
    private static func sha256Hex(in line: String) -> String? {
        guard line.hasPrefix("sha256 `"), line.hasSuffix("`") else { return nil }
        let hex = line.dropFirst("sha256 `".count).dropLast()
        return hex.count == 64 && hex.allSatisfy(\.isHexDigit) ? String(hex) : nil
    }
}
