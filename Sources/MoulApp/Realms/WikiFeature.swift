import GnoKit
import SwiftUI

/// The first feature that writes text, not just a number.
///
/// Reading is `RealmBrowser`, as for Blog. Writing hangs off the realm's own
/// `edit` links: each article renders one as a `txlink` to `Edit`, and the app
/// takes that offer and opens an editor on the page's source instead of a
/// gnoweb form. The source comes from `Title/raw` and is checked against the
/// sha256 printed beside it, so the next revision starts from the bytes on
/// chain and not from the rendered article, whose links are already expanded.
enum WikiFeature {
    static let descriptor = FeatureDescriptor(
        title: "Wiki",
        blurb: "gno.land/r/moul/x/wiki/v0, read and edited on the device",
        symbol: "books.vertical",
        realm: "gno.land/r/moul/x/wiki/v0",
        writes: true,
        // An edit locks a storage deposit of 100 ugnot per byte it adds
        // (175 bytes held 0.0175 GNOT on 2026-10-01), plus gas. Ten GNOT is
        // about 100 KB of new text.
        budget: 10_000_000
    )

    static let feature = Feature(descriptor: descriptor) { model in
        AnyView(WikiView(model: model))
    }
}

struct WikiView: View {
    let model: AppModel

    @State private var editing: EditTarget?
    @State private var reload = 0

    struct EditTarget: Identifiable {
        let id = UUID()
        /// Empty for a page that does not exist yet.
        let title: String
    }

    var body: some View {
        RealmBrowser(
            model: model,
            descriptor: WikiFeature.descriptor,
            reload: reload,
            onCall: { call in
                guard call.function == "Edit", let title = call.args["title"] else { return false }
                editing = EditTarget(title: title)
                return true
            },
            actions: {
                Button {
                    editing = EditTarget(title: "")
                } label: {
                    Label("New page", systemImage: "square.and.pencil")
                }
            }
        )
        .sheet(item: $editing) { target in
            WikiEditor(model: model, title: target.title) {
                reload += 1
            }
        }
    }
}

struct WikiEditor: View {
    let model: AppModel
    let onSaved: () -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var title: String
    @State private var text = ""
    @State private var summary = ""
    @State private var source: GnoWikiSource?
    @State private var loading: Bool
    @State private var busy = false
    @State private var error: String?

    private let isNew: Bool

    init(model: AppModel, title: String, onSaved: @escaping () -> Void) {
        self.model = model
        self.onSaved = onSaved
        _title = State(initialValue: title)
        _loading = State(initialValue: !title.isEmpty)
        isNew = title.isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                if isNew {
                    Section("Title") {
                        TextField("Page title", text: $title)
                            .textInputAutocapitalization(.sentences)
                    }
                }

                Section {
                    if loading {
                        ProgressView().frame(maxWidth: .infinity)
                    } else {
                        TextEditor(text: $text)
                            .font(.system(.body, design: .monospaced))
                            .frame(minHeight: 280)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                } header: {
                    Text(source.map { "Source, rev \($0.revision)" } ?? "Source")
                } footer: {
                    if let source, !source.verified {
                        Text("The source read back does not match its sha256 on chain. Saving will still work, but check the text first.")
                            .foregroundStyle(.orange)
                    } else {
                        Text("Wiki markup: [[Page]] links, [[Category:Name]] files the page.")
                    }
                }

                Section("Summary") {
                    TextField("What changed", text: $summary)
                }

                Section {
                    EmptyView()
                } footer: {
                    if !covered {
                        Text("The live grant does not cover this realm. It needs a new session.")
                    } else {
                        Text("Signed by this device's session key, attributed on chain to the master. The edit locks a storage deposit for the bytes it adds.")
                    }
                }

                if let error {
                    Section {
                        Text(error).font(.caption).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(isNew ? "New page" : title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }
                        .disabled(!canSave)
                }
            }
            .overlay { if busy { ProgressView().controlSize(.large) } }
            .interactiveDismissDisabled(busy || changed)
            .task { await load() }
        }
    }

    private var covered: Bool {
        model.grant?.covers(realm: WikiFeature.descriptor.realm) ?? false
    }

    private var changed: Bool { text != (source?.body ?? "") }

    private var canSave: Bool {
        covered && !busy && !loading && changed
            && !title.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func load() async {
        guard !isNew else { return }
        defer { loading = false }
        do {
            // Titles normalize `_` to a space, and a render path cannot carry one.
            let page = title.replacingOccurrences(of: " ", with: "_")
            let markdown = try await model.render(WikiFeature.descriptor.realm, path: page + "/raw")
            // A page that does not exist renders an invitation, not a source:
            // the editor then creates it.
            source = GnoWikiSource.parse(markdown)
            text = source?.body ?? ""
        } catch let failure as GnoError {
            error = failure.displayText
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func save() async {
        busy = true
        defer { busy = false }
        do {
            try await model.call(
                WikiFeature.descriptor.realm,
                "Edit",
                args: [title.trimmingCharacters(in: .whitespaces), text, summary]
            )
            onSaved()
            dismiss()
        } catch let failure as GnoError {
            error = failure.displayText
        } catch {
            self.error = error.localizedDescription
        }
    }
}
