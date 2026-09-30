import GnoKit
import SwiftUI

/// The handoff.
///
/// The app mints its own key and can do nothing with it: the chain denies every
/// `auth/*` message to a session, so only the master can turn this key into a
/// signer. That is the whole screen, and it is why the demo is worth showing:
/// the phone never sees a master key, and the grant it gets is scoped to the
/// realms the app actually has features for, with a spend limit it declared
/// up front.
struct GrantView: View {
    @Bindable var model: AppModel
    @State private var showingQR = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header

                CopyableText(label: "session public key", text: model.sessionPubKeyBech32)
                CopyableText(label: "session address", text: model.sessionBech32)

                scope

                VStack(alignment: .leading, spacing: 10) {
                    Text("Run this on your desktop")
                        .font(.headline)
                    Text("Only the master account can create a session. This app cannot grant itself anything.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    CopyableText(label: "1. measure, broadcasts nothing", text: model.grantCommandMeasure)
                    CopyableText(label: "2. broadcast, with what step 1 printed", text: model.grantCommandBroadcast)
                    Text("""
                    Two steps because the app cannot size this one: simulating it needs the \
                    master's key, which is the thing this whole screen exists to avoid putting \
                    on a phone. Everything the app signs afterwards is sized from a simulation.
                    """)
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                    Button {
                        showingQR.toggle()
                    } label: {
                        Label(showingQR ? "Hide the QR" : "Show the public key as a QR", systemImage: "qrcode")
                    }
                    .buttonStyle(.bordered)

                    if showingQR {
                        HStack {
                            Spacer()
                            QRCodeView(text: model.sessionPubKeyBech32)
                            Spacer()
                        }
                    }
                }

                waiting
            }
            .padding()
        }
        .navigationTitle("Grant a session")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Mint a new key") {
                    Task {
                        await model.forgetSessionKey()
                        await model.start()
                    }
                }
                .font(.caption)
            }
        }
        .task { model.startPolling() }
        .onDisappear { model.stopPolling() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("This device minted a key")
                .font(.title2.weight(.semibold))
            Text("""
            It is stored in the app's own keybase and never leaves the phone. \
            Until the master grants it, it can sign nothing.
            """)
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
    }

    private var scope: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("What it is asking for")
                .font(.headline)

            ForEach(model.requestedPaths, id: \.self) { path in
                Label(path, systemImage: "checkmark.seal")
                    .font(.system(.caption, design: .monospaced))
            }

            Label(
                "\(GnoCoin.ugnot(model.requestedBudget).display) lifetime cap",
                systemImage: "gauge.with.dots.needle.33percent"
            )
            .font(.caption)

            Text("""
            The scope is derived from the features in this build, not typed by hand. \
            A grant cannot be widened later, so a feature added after the ceremony needs a new session.
            """)
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
    }

    private var waiting: some View {
        HStack(spacing: 10) {
            ProgressView()
            VStack(alignment: .leading) {
                Text("Watching the chain")
                    .font(.subheadline.weight(.medium))
                Text("The app unlocks itself the moment the grant lands.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Check now") {
                Task { await model.refreshGrant() }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(12)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
    }
}

