import Foundation

/// A record paired with its unwrapped database id, for use as a `List` row.
///
/// Two selection channels in a `List` both key off the row's identity, and both
/// were optional here:
///
/// - `ForEach(records, id: \.id)` made the element identity `Optional<Int64>`.
/// - `.tag(record.id)` wrote a tag of type `Optional<Int64>`, while
///   `List(selection:)` with `@State var selectedID: Int64?` infers
///   `SelectionValue == Int64` and looks the tag up *by type*.
///
/// Either mismatch is enough to make a list unselectable, and SwiftUI reports
/// neither — the list keeps scrolling and simply never highlights. Iterating
/// `PersistedRow` fixes both at once, since its `ID` is a plain `Int64`.
///
/// Note this is specific to `List`. A `Picker` bound to `Binding<Int64?>` has
/// `SelectionValue == Optional<Int64>` and genuinely wants optional tags; see
/// `NewTabSheet.contextStrip`.
struct PersistedRow<Value>: Identifiable {
    let id: Int64
    let value: Value

    /// Pair each element with its id, dropping any that aren't persisted yet.
    /// An unsaved record has no identity to tag with, and dropping it beats a
    /// sentinel id that two unsaved rows would collide on. In practice these
    /// lists are populated straight from SQLite, so nothing is ever dropped.
    ///
    /// Deliberately not an `Array` extension: that would offer the method on
    /// every array in the module.
    static func rows(from elements: [Value], by id: (Value) -> Int64?) -> [PersistedRow<Value>] {
        elements.compactMap { element in
            id(element).map { PersistedRow(id: $0, value: element) }
        }
    }
}
