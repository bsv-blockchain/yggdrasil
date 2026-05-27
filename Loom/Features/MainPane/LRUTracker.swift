import Foundation

/// Pure LRU bookkeeping for the WebView pool (spec §Phase 5: max 8 live,
/// LRU eviction). Insertion preserves order; touching an existing key moves it
/// to the most-recent position; exceeding capacity evicts the least-recent.
///
/// Not thread-safe by design — callers single-thread access (MainActor for the
/// WebView pool).
struct LRUTracker<Key: Hashable> {
    let capacity: Int
    private var order: [Key] = []
    private var present: Set<Key> = []

    init(capacity: Int) {
        self.capacity = max(capacity, 1)
    }

    /// Bring `key` to most-recent. Returns the evicted key if `capacity` was
    /// exceeded; nil otherwise.
    @discardableResult
    mutating func touch(_ key: Key) -> Key? {
        if present.contains(key) {
            order.removeAll(where: { $0 == key })
            order.append(key)
            return nil
        }
        order.append(key)
        present.insert(key)
        guard order.count > capacity else { return nil }
        let evicted = order.removeFirst()
        present.remove(evicted)
        return evicted
    }

    mutating func remove(_ key: Key) {
        order.removeAll(where: { $0 == key })
        present.remove(key)
    }

    var keysInLRUOrder: [Key] {
        order
    }
}
