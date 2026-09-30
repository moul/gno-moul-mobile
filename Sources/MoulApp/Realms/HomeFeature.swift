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
    @State private var markdown = ""
    @State private var error: String?
    @State private var loading = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if loading {
                    ProgressView().frame(maxWidth: .infinity)
                } else if let error {
                    ContentUnavailableView("Could not read the realm", systemImage: "wifi.slash", description: Text(error))
                } else {
                    RealmMarkdown(source: markdown)
                }
            }
            .padding()
        }
        .refreshable { await load() }
        .task { await load() }
    }

    private func load() async {
        loading = markdown.isEmpty
        do {
            markdown = try await model.render(HomeFeature.descriptor.realm)
            error = nil
        } catch let failure as GnoError {
            error = failure.displayText
        } catch {
            self.error = error.localizedDescription
        }
        loading = false
    }
}
