import Foundation

/// Fixed-capacity ring buffer that retains the last `capacity` bytes appended.
/// Used by `CodingAgentRunner` to keep the tail of an agent's stdout/stderr so
/// Phase 6's fallback status detection has something to look at when the agent
/// isn't writing structured session JSONL.
///
/// Not thread-safe — callers are expected to call `append` from a single
/// PTY-read context.
struct OutputRingBuffer {
    let capacity: Int
    private var storage: Data
    /// Total number of bytes appended over the lifetime of this buffer. Used to
    /// detect overflow without materialising a larger array.
    private var totalAppended: Int = 0

    init(capacity: Int) {
        self.capacity = max(capacity, 0)
        self.storage = Data()
        self.storage.reserveCapacity(self.capacity)
    }

    /// 4KB default per spec §Phase 3.
    static func makeAgentOutputRing() -> OutputRingBuffer {
        OutputRingBuffer(capacity: 4096)
    }

    var count: Int { storage.count }

    mutating func append(_ data: Data) {
        guard capacity > 0, !data.isEmpty else { return }
        totalAppended += data.count
        if data.count >= capacity {
            // The incoming chunk alone overflows: keep only its tail.
            storage = data.suffix(capacity)
            return
        }
        storage.append(data)
        if storage.count > capacity {
            // Drop the oldest bytes.
            storage = storage.suffix(capacity)
        }
    }

    func contents() -> Data {
        storage
    }
}
