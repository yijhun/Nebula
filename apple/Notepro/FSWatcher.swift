import Foundation
import CoreServices

/// Watches a directory tree (FSEvents) and fires `onChange` (debounced by the
/// stream latency) whenever anything under it is created/modified/deleted —
/// covers both external edits and the app's own saves.
final class FSWatcher {
    private var stream: FSEventStreamRef?
    private let onChange: ([String]) -> Void

    /// `onChange` receives the changed file paths (may be empty on overflow).
    init(onChange: @escaping ([String]) -> Void) { self.onChange = onChange }

    func start(_ url: URL) {
        stop()
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, numEvents, eventPaths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<FSWatcher>.fromOpaque(info).takeUnretainedValue()
            // eventPaths is a CFArray of CFStrings ONLY because the stream is
            // created with kFSEventStreamCreateFlagUseCFTypes below — without
            // that flag it's a raw char** and this cast segfaults.
            let paths = (Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue()
                         as? [String]) ?? []
            _ = numEvents
            DispatchQueue.main.async { watcher.onChange(paths) }
        }
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer
                           | kFSEventStreamCreateFlagUseCFTypes)
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault, callback, &context,
            [url.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.8, // latency (seconds) — coalesces bursts
            flags
        ) else { return }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, DispatchQueue.main)
        FSEventStreamStart(stream)
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    deinit { stop() }
}
