import CoreServices
import Foundation

/// Calls `onChange` on the main queue when anything inside `directory` changes, or
/// only a file named `fileName` if given.
///
/// Uses FSEvents with file-level events, which catches both in-place writes and
/// atomic saves (write a temp file, then rename over the original). Events within
/// `latency` seconds are coalesced into one call.
final class DirectoryWatcher {
    private final class Handler: Sendable {
        let fileName: String?
        let onChange: @MainActor @Sendable () -> Void
        init(_ fileName: String?, _ onChange: @escaping @MainActor @Sendable () -> Void) {
            self.fileName = fileName
            self.onChange = onChange
        }
    }

    private let handler: Handler
    private var stream: FSEventStreamRef?

    init(directory: URL, fileName: String? = nil, latency: TimeInterval = 0.15, onChange: @escaping @MainActor @Sendable () -> Void) {
        handler = Handler(fileName, onChange)
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(handler).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, _, eventPaths, _, _ in
            guard let info else { return }
            let handler = Unmanaged<Handler>.fromOpaque(info).takeUnretainedValue()
            // Compare names only: FSEvents reports resolved paths (/private/var/… for /var/…).
            if let fileName = handler.fileName {
                let paths = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue() as? [String] ?? []
                guard paths.contains(where: { ($0 as NSString).lastPathComponent == fileName }) else { return }
            }
            // The stream is scheduled on the main queue below.
            MainActor.assumeIsolated { handler.onChange() }
        }
        stream = FSEventStreamCreate(
            nil,
            callback,
            &context,
            [directory.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes)
        )
        if let stream {
            FSEventStreamSetDispatchQueue(stream, .main)
            FSEventStreamStart(stream)
        }
    }

    deinit {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }
}
