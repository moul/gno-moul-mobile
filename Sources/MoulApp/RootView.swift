import SwiftUI

struct RootView: View {
    @Bindable var model: AppModel

    var body: some View {
        switch model.stage {
        case .starting:
            StartingView()
        case .awaitingGrant, .ready:
            // Reading a realm needs no session at all, so the app is usable
            // before the ceremony and the grant lives in its own tab. Gating
            // everything behind it would make the demo look like a wallet.
            FeatureTabs(model: model)
        case let .failed(message):
            FailureView(message: message) {
                Task { await model.start() }
            }
        }
    }
}

private struct StartingView: View {
    var body: some View {
        VStack(spacing: 16) {
            ProgressView()
            Text("Starting the gno core")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}

private struct FailureView: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("Could not start", systemImage: "exclamationmark.triangle")
        } description: {
            Text(message)
        } actions: {
            Button("Try again", action: retry)
                .buttonStyle(.borderedProminent)
        }
    }
}

struct FeatureTabs: View {
    @Bindable var model: AppModel
    @State private var selection: String = Self.launchTab ?? Features.all[0].id

    /// Lets a screenshot or a UI run open straight onto one tab:
    /// `xcrun simctl launch booted land.gno.moul.app -tab Counter`.
    private static var launchTab: String? {
        guard let name = UserDefaults.standard.string(forKey: "tab") else { return nil }
        return Features.all.first { $0.descriptor.title == name }?.id ?? (name == "Session" ? "session" : nil)
    }

    var body: some View {
        TabView(selection: $selection) {
            ForEach(Features.all) { feature in
                NavigationStack {
                    feature.screen(model)
                        .navigationTitle(feature.descriptor.title)
                }
                .tabItem {
                    Label(feature.descriptor.title, systemImage: feature.descriptor.symbol)
                }
                .tag(feature.id)
            }

            NavigationStack {
                if model.isReady {
                    SessionView(model: model)
                        .navigationTitle("Session")
                } else {
                    GrantView(model: model)
                }
            }
            .tabItem { Label("Session", systemImage: "key.radiowaves.forward") }
            .tag("session")
            .badge(model.isReady ? 0 : 1)
        }
    }
}
