import SwiftUI

/// What a feature tells the rest of the app about itself.
///
/// The session's scope is derived from these, not written by hand. That matters
/// because a grant cannot be widened after the fact: adding a feature that
/// writes means the app must ask for a new grant, and it can only know that if
/// every feature declares its realm here.
struct FeatureDescriptor: Identifiable, Hashable, Sendable {
    var id: String { realm + "#" + title }
    let title: String
    let blurb: String
    let symbol: String
    /// The realm this feature reads and, if it writes, calls.
    let realm: String
    /// False for read-only features: they need no grant at all.
    let writes: Bool
    /// Headroom in ugnot this feature wants inside the session's spend limit.
    /// Only gas and storage deposit are charged against it for a call that
    /// sends nothing, so this is small on purpose.
    let budget: Int64

    /// The AllowPaths entry that covers it.
    var allowPath: String { "vm/exec:" + realm }
}

/// A feature is a descriptor plus a screen. Adding one is one file and one line
/// in `Features.all`.
struct Feature: Identifiable {
    let descriptor: FeatureDescriptor
    let screen: @MainActor (AppModel) -> AnyView

    var id: String { descriptor.id }
}

enum Features {
    static let all: [Feature] = [
        HomeFeature.feature,
        CounterFeature.feature,
    ]

    /// Everything the session must be allowed to call.
    static var allowPaths: [String] {
        Array(Set(all.filter(\.descriptor.writes).map(\.descriptor.allowPath))).sorted()
    }

    /// The spend limit to ask for, in ugnot.
    static var budget: Int64 {
        all.filter(\.descriptor.writes).map(\.descriptor.budget).reduce(0, +)
    }
}
