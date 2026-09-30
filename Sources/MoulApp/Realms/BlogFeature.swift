import GnoKit
import SwiftUI

/// The third feature, added after the first two, and the proof that adding one
/// is a file and a line.
///
/// It also exercises the part of `Render` the other two do not: a realm whose
/// index links to its own sub-pages. Those links are relative
/// (`/r/moul/blog:slug`), so they mean nothing to a browser on a phone; the app
/// intercepts them and renders the sub-page from the same realm instead.
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
        AnyView(BlogView(model: model))
    }
}

struct BlogView: View {
    let model: AppModel
    @State private var path: [String] = []

    var body: some View {
        NavigationStack(path: $path) {
            RealmPage(model: model, realm: BlogFeature.descriptor.realm, path: "")
                .navigationTitle(BlogFeature.descriptor.title)
                .navigationDestination(for: String.self) { subpath in
                    RealmPage(model: model, realm: BlogFeature.descriptor.realm, path: subpath)
                        .navigationTitle(subpath)
                        .navigationBarTitleDisplayMode(.inline)
                }
        }
        .environment(\.openURL, OpenURLAction { url in
            // A realm links to itself as `/r/ns/name:subpath`. Everything else,
            // including a real https link in a post, goes to the browser.
            guard let subpath = GnoRealmLink.renderPath(of: url, in: BlogFeature.descriptor.realm) else {
                return .systemAction
            }
            path.append(subpath)
            return .handled
        })
    }

}

/// One `Render` call, shown.
struct RealmPage: View {
    let model: AppModel
    let realm: String
    let path: String

    @State private var markdown = ""
    @State private var error: String?
    @State private var loading = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if loading {
                    ProgressView().frame(maxWidth: .infinity)
                } else if let error {
                    ContentUnavailableView(
                        "Could not read the realm",
                        systemImage: "wifi.slash",
                        description: Text(error)
                    )
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
            markdown = try await model.render(realm, path: path)
            error = nil
        } catch let failure as GnoError {
            error = failure.displayText
        } catch {
            self.error = error.localizedDescription
        }
        loading = false
    }
}
