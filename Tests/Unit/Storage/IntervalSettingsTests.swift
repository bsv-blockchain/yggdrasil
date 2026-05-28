@testable import Yggdrasil
import XCTest

/// Pure-logic tests for IntervalSettings. The store layer is injected via a
/// `KeyValueStore` protocol so we don't open a real GRDB connection here.
final class IntervalSettingsTests: XCTestCase {
    private final class MemoryKVStore: IntervalSettingsKVStore {
        var dict: [String: String] = [:]
        func get(forKey key: String) throws -> String? { dict[key] }
        func set(_ value: String, forKey key: String) throws { dict[key] = value }
    }

    func test_load_emptyStore_returnsDefaults() throws {
        let settings = try IntervalSettings.load(from: MemoryKVStore())
        XCTAssertEqual(settings, IntervalSettings.defaults)
        XCTAssertEqual(settings.syncSeconds, 60)
        XCTAssertEqual(settings.statusProbeSeconds, 5)
    }

    func test_load_validStoredValues_returnsThem() throws {
        let store = MemoryKVStore()
        store.dict["intervals.syncSeconds"] = "30"
        store.dict["intervals.statusProbeSeconds"] = "10"
        let settings = try IntervalSettings.load(from: store)
        XCTAssertEqual(settings.syncSeconds, 30)
        XCTAssertEqual(settings.statusProbeSeconds, 10)
    }

    func test_load_garbageStoredValues_fallsBackToDefaults() throws {
        let store = MemoryKVStore()
        store.dict["intervals.syncSeconds"] = "not a number"
        store.dict["intervals.statusProbeSeconds"] = ""
        let settings = try IntervalSettings.load(from: store)
        XCTAssertEqual(settings, IntervalSettings.defaults)
    }

    func test_load_outOfRangeValues_clampsToRange() throws {
        let store = MemoryKVStore()
        store.dict["intervals.syncSeconds"] = "5"       // below min (15)
        store.dict["intervals.statusProbeSeconds"] = "120" // above max (60)
        let settings = try IntervalSettings.load(from: store)
        XCTAssertEqual(settings.syncSeconds, IntervalSettings.syncRange.lowerBound)
        XCTAssertEqual(settings.statusProbeSeconds, IntervalSettings.statusProbeRange.upperBound)
    }

    func test_save_roundTrip() throws {
        let store = MemoryKVStore()
        let written = IntervalSettings(syncSeconds: 45, statusProbeSeconds: 8)
        try written.save(to: store)
        let readBack = try IntervalSettings.load(from: store)
        XCTAssertEqual(readBack, written)
    }

    func test_save_clampsOutOfRange() throws {
        let store = MemoryKVStore()
        let unsafe = IntervalSettings(syncSeconds: 999, statusProbeSeconds: 1)
        try unsafe.save(to: store)
        let readBack = try IntervalSettings.load(from: store)
        XCTAssertEqual(readBack.syncSeconds, IntervalSettings.syncRange.upperBound)
        XCTAssertEqual(readBack.statusProbeSeconds, IntervalSettings.statusProbeRange.lowerBound)
    }
}
