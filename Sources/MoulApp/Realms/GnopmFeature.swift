import GnoKit
import SwiftUI

/// Where a deployed package says it came from.
///
/// Read-only on purpose. `Register` takes a repository, a commit and a
/// directory, which is a claim about code on a laptop, not something to type on
/// a phone; and the realm records testimony, so the useful thing to carry around
/// is the reading side: who claimed what, and whether the owner did.
enum GnopmFeature {
    static let descriptor = FeatureDescriptor(
        title: "gnopm",
        blurb: "gno.land/r/moul/gnopm/registry/v0, the source registry",
        symbol: "shippingbox",
        realm: "gno.land/r/moul/gnopm/registry/v0",
        writes: false,
        budget: 0
    )

    static let feature = Feature(descriptor: descriptor) { model in
        AnyView(RealmBrowser(model: model, descriptor: descriptor))
    }
}
