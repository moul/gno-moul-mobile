import Foundation

/// Links that a realm writes about itself.
///
/// A realm's `Render` output is markdown meant for gnoweb, so its internal links
/// are site-relative: `/r/moul/blog:gnopm`. They have no host, so handing one to
/// a browser does nothing useful; an app has to recognise them and render the
/// page itself.
///
/// The separator is a colon, and that is specifically gnoweb's **render path**
/// separator, not the sub-realm one. A sub-realm is spelled with `#`, and
/// `/r/moul/blog/gnopm` would be a different package altogether.
public enum GnoRealmLink {
    /// The render path of `url` when it points at a page of `realm`, else nil.
    ///
    /// Accepts both the site-relative form a realm writes and a full URL, so a
    /// markdown parser that resolved the link against a host does not break it.
    public static func renderPath(of url: URL, in realm: String) -> String? {
        let text = url.absoluteString
        let relative = text.hasPrefix("/") ? text : (url.host == nil ? text : url.path)

        guard let separator = relative.firstIndex(of: ":") else { return nil }
        let package = String(relative[relative.startIndex..<separator])
        guard !package.isEmpty, realm.hasSuffix(package) else { return nil }

        let path = String(relative[relative.index(after: separator)...])
        return path.isEmpty ? nil : path
    }

    /// A transaction a realm offers from its own page.
    public struct Call: Equatable, Sendable {
        public let function: String
        public let args: [String: String]
    }

    /// The call `url` proposes when it is a `txlink` of `realm`, else nil.
    ///
    /// gnoweb spells these `/r/ns/name$help&func=Edit&title=Gno`, which opens a
    /// form prefilled with the arguments. They are offers, never transactions:
    /// the app decides what to do with one, and the default is nothing.
    ///
    /// The query is form-encoded, so a `+` is a space: `title=Gno+land` is the
    /// page "Gno land", and decoding it as a URL would name a page that does not
    /// exist.
    public static func call(of url: URL, in realm: String) -> Call? {
        let text = url.absoluteString
        // Still percent-encoded: decoding before splitting on `&` would cut a
        // title that contains one.
        let relative = text.hasPrefix("/") || url.host == nil
            ? text
            : (URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? text)

        guard let dollar = relative.firstIndex(of: "$") else { return nil }
        let package = String(relative[relative.startIndex..<dollar])
        guard !package.isEmpty, realm.hasSuffix(package) else { return nil }

        var function: String?
        var args: [String: String] = [:]
        for pair in relative[relative.index(after: dollar)...].split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            let value = parts[1].removingPercentEncoding ?? parts[1]
            if parts[0] == "func" { function = value } else { args[parts[0]] = value }
        }
        guard let function, !function.isEmpty else { return nil }
        return Call(function: function, args: args)
    }
}
