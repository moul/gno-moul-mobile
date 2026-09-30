import GnoKit
import SwiftUI

/// The read path: a realm's `Render` is its front end, and this shows it as it
/// is, with no server in between.
enum HomeFeature {
    static let descriptor = FeatureDescriptor(
        title: "Home",
        blurb: "gno.land/r/moul/home, rendered on the device",
        symbol: "person.crop.square",
        realm: "gno.land/r/moul/home",
        writes: false,
        budget: 0
    )

    static let feature = Feature(descriptor: descriptor) { model in
        AnyView(HomeView(model: model))
    }
}

struct HomeView: View {
    let model: AppModel

    var body: some View {
        NavigationStack {
            RealmPage(model: model, realm: HomeFeature.descriptor.realm, path: "")
                .navigationTitle(HomeFeature.descriptor.title)
        }
    }
}
