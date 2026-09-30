import GnoKit
import SwiftUI

/// The write path, and the smallest thing that proves the session works.
///
/// `Inc` costs gas and a storage deposit and sends nothing, which is exactly the
/// shape a session budget covers: `MsgCall.SpendForSigner` returns `msg.Send`,
/// so a call that sends zero only ever charges the limit for its gas.
enum CounterFeature {
    static let descriptor = FeatureDescriptor(
        title: "Counter",
        blurb: "One number, moved by a session-signed transaction",
        symbol: "plusminus.circle",
        realm: "gno.land/r/moul/x/daily/counter/v0",
        writes: true,
        // Room for a few hundred calls at the ~10k ugnot a simulated Inc reports.
        budget: 5_000_000
    )

    static let feature = Feature(descriptor: descriptor) { model in
        AnyView(CounterView(model: model))
    }
}

struct CounterView: View {
    let model: AppModel

    @State private var value: String = "-"
    @State private var total: String = "-"
    @State private var busy = false
    @State private var lastReceipt: Receipt?
    @State private var error: String?

    struct Receipt: Identifiable {
        let id = UUID()
        let hash: String
        let fee: String
        let storage: String
    }

    var body: some View {
        NavigationStack {
        List {
            Section {
                VStack(spacing: 4) {
                    Text(value)
                        .font(.system(size: 64, weight: .light, design: .rounded))
                        .contentTransition(.numericText())
                    Text("\(total) changes all time")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            }

            Section {
                HStack {
                    Button {
                        Task { await send("Dec") }
                    } label: {
                        Label("Dec", systemImage: "minus").frame(maxWidth: .infinity)
                    }
                    Button {
                        Task { await send("Inc") }
                    } label: {
                        Label("Inc", systemImage: "plus").frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(busy || !covered)
            } footer: {
                if !covered {
                    Text("The live grant does not cover this realm. It needs a new session.")
                } else {
                    Text("Signed by this device's session key, attributed on chain to the master.")
                }
            }

            if let lastReceipt {
                Section("Last transaction") {
                    LabeledContent("fee", value: lastReceipt.fee)
                    LabeledContent("storage", value: lastReceipt.storage)
                    CopyableText(label: "hash", text: lastReceipt.hash)
                        .listRowInsets(EdgeInsets())
                }
            }

            if let error {
                Section {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }
        }
        .navigationTitle(CounterFeature.descriptor.title)
        .overlay { if busy { ProgressView().controlSize(.large) } }
        .refreshable { await read() }
        .task { await read() }
        }
    }

    private var covered: Bool {
        model.grant?.covers(realm: CounterFeature.descriptor.realm) ?? false
    }

    private func read() async {
        async let current = try? model.eval(CounterFeature.descriptor.realm, "Value()")
        async let all = try? model.eval(CounterFeature.descriptor.realm, "Total()")
        value = (await current).flatMap { GnoQEval.scalar($0) } ?? value
        total = (await all).flatMap { GnoQEval.scalar($0) } ?? total
    }

    private func send(_ function: String) async {
        busy = true
        defer { busy = false }
        do {
            let (result, fees) = try await model.call(CounterFeature.descriptor.realm, function)
            lastReceipt = Receipt(
                hash: result.hashHex ?? "",
                fee: fees.gasFee?.display ?? "-",
                storage: fees.storageFee?.first?.display ?? "0 GNOT"
            )
            error = nil
            await read()
        } catch let failure as GnoError {
            error = failure.displayText
        } catch {
            self.error = error.localizedDescription
        }
    }

}
