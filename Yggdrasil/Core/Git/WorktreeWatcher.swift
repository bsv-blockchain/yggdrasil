import CoreServices
import Foundation

/// Recursive directory watcher backed by `FSEventStream`. Used by the
/// diff pane so a save (or `git add`, `git commit`, etc.) inside the
/// worktree triggers an automatic re-render without the user having to
/// switch tabs or click anything.
///
/// Lifetime is tied to the owning object. `start()` registers a
/// callback on the main dispatch queue; `stop()` (and `deinit`)
/// invalidates the stream. Calls into `onChange` are debounced so a
/// burst of saves only triggers one re-render.
final class WorktreeWatcher {
    private let path: String
    private let onChange: @MainActor () -> Void
    private let debounceMs: Int
    private var stream: FSEventStreamRef?
    private var pendingTask: Task<Void, Never>?

    init(path: String, debounceMs: Int = 200, onChange: @escaping @MainActor () -> Void) {
        self.path = path
        self.debounceMs = debounceMs
        self.onChange = onChange
    }

    deinit { stopUnsafe() }

    @MainActor
    func start() {
        guard stream == nil else { return }
        let info = Unmanaged.passUnretained(self).toOpaque()
        var context = FSEventStreamContext(
            version: 0, info: info, retain: nil, release: nil, copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<WorktreeWatcher>.fromOpaque(info).takeUnretainedValue()
            Task { @MainActor in watcher.scheduleFire() }
        }
        // kFSEventStreamCreateFlagFileEvents: per-file granularity so
        //   an `:w` in vim or a `claude` write fires straightaway.
        // kFSEventStreamCreateFlagIgnoreSelf: skip events caused by our
        //   own process (rare in the diff path, but cheap insurance).
        // kFSEventStreamCreateFlagNoDefer: deliver the first event of a
        //   burst immediately rather than waiting for the latency
        //   window to expire — the debounce on our side handles
        //   coalescing.
        let flags =
            UInt32(kFSEventStreamCreateFlagFileEvents)
                | UInt32(kFSEventStreamCreateFlagIgnoreSelf)
                | UInt32(kFSEventStreamCreateFlagNoDefer)
        guard let s = FSEventStreamCreate(
            nil, callback, &context,
            [path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.1, // CFAbsoluteTime: kernel latency window (seconds)
            flags
        ) else {
            YggdrasilLog.ui.warning(
                "WorktreeWatcher: FSEventStreamCreate returned nil for \(self.path, privacy: .public)"
            )
            return
        }
        FSEventStreamSetDispatchQueue(s, DispatchQueue.main)
        FSEventStreamStart(s)
        stream = s
    }

    func stop() {
        stopUnsafe()
    }

    /// Same as `stop()` but safe from `deinit` (no Swift concurrency
    /// hops). The FSEventStream API is not actor-isolated.
    private func stopUnsafe() {
        if let s = stream {
            FSEventStreamStop(s)
            FSEventStreamInvalidate(s)
            FSEventStreamRelease(s)
            stream = nil
        }
        pendingTask?.cancel()
        pendingTask = nil
    }

    @MainActor
    private func scheduleFire() {
        pendingTask?.cancel()
        let delay = debounceMs
        let cb = onChange
        pendingTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(delay))
            guard !Task.isCancelled else { return }
            cb()
        }
    }
}
