import Foundation

/// Reading what `vm/qeval` answers.
///
/// The reply is a typed literal, one per return value: `(42 int)`, and for a
/// realm-defined type `(1 gno.land/r/demo/boards.BoardID)`. The type is not
/// noise to strip, it is half the answer, and stripping it with something like
/// "keep only the digits" silently turns `(7 int64)` into 764.
public enum GnoQEval {
    /// One returned value: its literal and its type.
    public struct Value: Equatable, Sendable {
        public let literal: String
        public let type: String
    }

    /// Splits a reply into its values, one per line.
    public static func values(_ reply: String) -> [Value] {
        reply
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .compactMap(value(ofLine:))
    }

    /// The first value's literal, which is what a one-result getter wants.
    public static func scalar(_ reply: String) -> String? {
        values(reply).first?.literal
    }

    public static func int(_ reply: String) -> Int64? {
        scalar(reply).flatMap(Int64.init)
    }

    private static func value(ofLine line: String) -> Value? {
        guard line.hasPrefix("("), line.hasSuffix(")") else { return nil }
        let inner = String(line.dropFirst().dropLast())
        // The type is the last space-separated token; the literal is everything
        // before it, so a string value containing spaces survives.
        guard let split = inner.lastIndex(of: " ") else { return nil }
        return Value(
            literal: String(inner[inner.startIndex..<split]),
            type: String(inner[inner.index(after: split)...])
        )
    }
}
