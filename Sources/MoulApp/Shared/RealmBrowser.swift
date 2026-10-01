import GnoKit
import SwiftUI

/// A realm's pages, browsed the way gnoweb does it but without leaving the app.
///
/// Blog showed the pattern and Wiki and gnopm needed exactly the same one, so it
/// lives here: a realm links to its own pages as `/r/ns/name:subpath`, and each
/// of those becomes a pushed page rendered from the same realm. Everything else
/// goes to the browser, except a `txlink` the feature chose to handle.
struct RealmBrowser<Actions: View>: View {
    let model: AppModel
    let descriptor: FeatureDescriptor
    /// Bump to re-read every page on the stack, after a write.
    let reload: Int
    let onCall: @MainActor (GnoRealmLink.Call) -> Bool
    let actions: Actions

    @State private var path: [String] = []

    init(
        model: AppModel,
        descriptor: FeatureDescriptor,
        reload: Int = 0,
        onCall: @escaping @MainActor (GnoRealmLink.Call) -> Bool = { _ in false },
        @ViewBuilder actions: () -> Actions
    ) {
        self.model = model
        self.descriptor = descriptor
        self.reload = reload
        self.onCall = onCall
        self.actions = actions()
    }

    var body: some View {
        NavigationStack(path: $path) {
            RealmPage(model: model, realm: descriptor.realm, path: "")
                .id(reload)
                .navigationTitle(descriptor.title)
                .toolbar { ToolbarItem(placement: .primaryAction) { actions } }
                .navigationDestination(for: String.self) { subpath in
                    RealmPage(model: model, realm: descriptor.realm, path: subpath)
                        .id("\(reload)/\(subpath)")
                        .navigationTitle(subpath)
                        .navigationBarTitleDisplayMode(.inline)
                }
        }
        .environment(\.openURL, OpenURLAction { url in
            if let subpath = GnoRealmLink.renderPath(of: url, in: descriptor.realm) {
                path.append(subpath)
                return .handled
            }
            if let call = GnoRealmLink.call(of: url, in: descriptor.realm), onCall(call) {
                return .handled
            }
            return .systemAction
        })
    }
}

extension RealmBrowser where Actions == EmptyView {
    init(model: AppModel, descriptor: FeatureDescriptor) {
        self.init(model: model, descriptor: descriptor) { EmptyView() }
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
