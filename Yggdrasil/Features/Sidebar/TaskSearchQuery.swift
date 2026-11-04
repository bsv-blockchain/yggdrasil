import Foundation

/// The task pickers' search box, parsed.
///
/// Every term has to match somewhere in the row — title, repo, number, state,
/// milestone or any label — and they're ANDed, so `P0 teranode` narrows rather
/// than widens. A term prefixed with `-` inverts: `-P0` keeps only the rows
/// where nothing matches "P0". There are no field prefixes; a term is tried
/// against every field, which is what makes `-P0` read the way you'd expect
/// without having to know it's a label.
///
/// Quotes hold a phrase together, because GitHub labels routinely contain
/// spaces: `"good first issue"` is one term, `good first issue` is three.
struct TaskSearchQuery {
    struct Term: Equatable {
        let text: String
        let isNegated: Bool
    }

    let terms: [Term]

    var isEmpty: Bool {
        terms.isEmpty
    }

    init(_ raw: String) {
        terms = Self.parse(raw)
    }

    /// True when `fields` satisfies every term. Matching is case-insensitive
    /// substring; an empty query matches everything.
    func matches(_ fields: [String]) -> Bool {
        guard !terms.isEmpty else { return true }
        let haystack = fields.map { $0.lowercased() }
        for term in terms {
            let hit = haystack.contains { $0.contains(term.text) }
            if hit == term.isNegated { return false }
        }
        return true
    }

    /// Split on whitespace, but keep a double-quoted run together. A leading
    /// `-` negates, including before a quote (`-"good first issue"`).
    ///
    /// Two cases exist because the box is parsed on every keystroke, so it is
    /// constantly half-typed: a lone `-` yields no term (rather than a term
    /// that matches everything and hides the whole list), and an unterminated
    /// quote runs to the end of the string.
    private static func parse(_ raw: String) -> [Term] {
        var terms: [Term] = []
        var current = ""
        var isNegated = false
        var isFresh = true // nothing accumulated into `current` yet
        var inQuotes = false

        func flush() {
            if !current.isEmpty {
                terms.append(Term(text: current.lowercased(), isNegated: isNegated))
            }
            current = ""
            isNegated = false
            isFresh = true
        }

        for character in raw {
            if character == "\"" {
                inQuotes.toggle()
                // A quote always starts a term, so `""` doesn't silently vanish
                // into "nothing was typed".
                isFresh = false
                continue
            }
            if character.isWhitespace, !inQuotes {
                flush()
                continue
            }
            if character == "-", isFresh, !inQuotes {
                isNegated = true
                isFresh = false
                continue
            }
            current.append(character)
            isFresh = false
        }
        flush()
        return terms
    }
}
