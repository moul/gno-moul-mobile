import GnoKit
import SwiftUI

/// The third feature, added after the first two, and the proof that adding one
/// is a file and a line.
///
/// It also exercises the part of `Render` the other two do not: a realm whose
/// index links to its own sub-pages. Those links are relative
/// (`/r/moul/blog:slug`), so they mean nothing to a browser on a phone; the app
/// intercepts them and renders the sub-page from the same realm instead. That
/// interception is `RealmBrowser`, shared with Wiki and gnopm.
enum BlogFeature {
    static let descriptor = FeatureDescriptor(
        title: "Blog",
        blurb: "gno.land/r/moul/blog, posts and all",
        symbol: "text.book.closed",
        realm: "gno.land/r/moul/blog",
        writes: false,
        budget: 0
    )

    static let feature = Feature(descriptor: descriptor) { model in
        AnyView(RealmBrowser(model: model, descriptor: descriptor))
    }
}
