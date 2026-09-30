import GnoKit
import SwiftUI

/// What the grant actually says, read back from the chain rather than from
/// whatever the app asked for.
struct SessionView: View {
    @Bindable var model: AppModel

    var body: some View {
        List {
            Section("Acting as") {
                LabeledContent("master", value: model.masterBech32)
                    .font(.system(.caption, design: .monospaced))
                Text("""
                A session delegates signing, not identity. Every call below is attributed to \
                the master: a realm that pays the caller pays the master, and a storage refund \
                lands there too.
                """)
                .font(.caption2)
                .foregroundStyle(.secondary)
            }

            Section("This device") {
                LabeledContent("session", value: model.sessionBech32)
                    .font(.system(.caption, design: .monospaced))
                LabeledContent("chain", value: model.chain.chainID)
            }

            if let grant = model.grant {
                Section("The grant, as the chain has it") {
                    if let limit = grant.limit {
                        LabeledContent("spend limit", value: limit.display)
                    }
                    LabeledContent("spent", value: grant.used.display)
                    if let fraction = grant.budgetUsedFraction {
                        ProgressView(value: fraction)
                    }
                    LabeledContent(
                        "period",
                        value: (grant.spendPeriod ?? 0) == 0
                            ? "lifetime cap"
                            : "\((grant.spendPeriod ?? 0) / 86_400) day rolling"
                    )
                    if let expiry = grant.expiry {
                        LabeledContent("expires", value: expiry.formatted(date: .abbreviated, time: .shortened))
                    } else {
                        LabeledContent("expires", value: "never")
                    }
                }

                Section("Allowed") {
                    ForEach(grant.allowPaths ?? [], id: \.self) { path in
                        Text(path).font(.system(.caption, design: .monospaced))
                    }
                }
            }

            if !model.uncoveredFeatures.isEmpty {
                Section("Not covered by this grant") {
                    ForEach(model.uncoveredFeatures) { descriptor in
                        Label(descriptor.realm, systemImage: "lock")
                            .font(.system(.caption, design: .monospaced))
                    }
                    Text("""
                    A grant cannot be widened. These features need a new session, \
                    created by the master with the wider scope.
                    """)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
            }

            Section {
                Button("Refresh from the chain") {
                    Task { await model.refreshGrant() }
                }
                Button("Forget this device's key", role: .destructive) {
                    Task {
                        await model.forgetSessionKey()
                        await model.start()
                    }
                }
            } footer: {
                Text("Forgetting the key ends the app's half. The grant stays live until the master revokes it.")
            }
        }
    }
}
