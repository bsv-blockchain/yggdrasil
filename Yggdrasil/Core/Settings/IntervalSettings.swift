import Foundation

/// Polling intervals that the user can change at runtime from
/// `IntervalsPrefsPane`. Persisted as plain strings in the `setting`
/// key-value table so they survive relaunch.
///
/// Values are clamped both on save (so a buggy caller can't poison the
/// store) and on load (so a hand-edited DB doesn't blow up the schedulers).
struct IntervalSettings: Equatable {
    /// Seconds between full GitHub syncs. Lower bound 15s — anything faster
    /// hammers `/search/issues` for negligible UX gain. Upper bound 600s —
    /// beyond that the reviewer pill feels broken.
    var syncSeconds: Int

    /// Seconds between per-tab git probes (status / ahead-behind). Lower
    /// bound 2s — git subprocess cost dominates below that. Upper bound
    /// 60s — slower than that and the sidebar pip lies about staleness.
    var statusProbeSeconds: Int

    static let defaults = IntervalSettings(syncSeconds: 60, statusProbeSeconds: 5)
    static let syncRange = 15 ... 600
    static let statusProbeRange = 2 ... 60

    private static let syncKey = "intervals.syncSeconds"
    private static let statusProbeKey = "intervals.statusProbeSeconds"

    static func load(from store: IntervalSettingsKVStore) throws -> IntervalSettings {
        let sync = try parseClamped(store.get(forKey: syncKey), range: syncRange,
                                    fallback: defaults.syncSeconds)
        let probe = try parseClamped(store.get(forKey: statusProbeKey), range: statusProbeRange,
                                     fallback: defaults.statusProbeSeconds)
        return IntervalSettings(syncSeconds: sync, statusProbeSeconds: probe)
    }

    func save(to store: IntervalSettingsKVStore) throws {
        let clampedSync = Self.syncRange.clamp(syncSeconds)
        let clampedProbe = Self.statusProbeRange.clamp(statusProbeSeconds)
        try store.set(String(clampedSync), forKey: Self.syncKey)
        try store.set(String(clampedProbe), forKey: Self.statusProbeKey)
    }

    private static func parseClamped(_ raw: String?, range: ClosedRange<Int>, fallback: Int) throws -> Int {
        guard let raw, let value = Int(raw.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return fallback
        }
        return range.clamp(value)
    }
}

/// Minimal storage abstraction so unit tests can inject an in-memory dict
/// instead of opening a real SQLite database. `SettingsStore` conforms to
/// it via the extension below.
protocol IntervalSettingsKVStore {
    func get(forKey key: String) throws -> String?
    func set(_ value: String, forKey key: String) throws
}

extension SettingsStore: IntervalSettingsKVStore {}

private extension ClosedRange where Bound == Int {
    func clamp(_ value: Int) -> Int {
        Swift.min(Swift.max(value, lowerBound), upperBound)
    }
}
