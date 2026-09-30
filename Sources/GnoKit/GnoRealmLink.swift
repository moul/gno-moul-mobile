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
}
