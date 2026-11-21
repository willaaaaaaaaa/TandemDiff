import CoreServices
import Foundation

@MainActor
final class FolderEvents {
    private var stream: FSEventStreamRef?
    private final class Handler {
        let changed: @MainActor () -> Void

        init(_ changed: @escaping @MainActor () -> Void) {
            self.changed = changed
        }
    }

    init(paths: [String], changed: @escaping @MainActor () -> Void) {
        let handler = Handler(changed)
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(handler).toOpaque(),
            retain: { raw in
                guard let raw else { return nil }
                _ = Unmanaged<Handler>.fromOpaque(raw).retain()
                return raw
            },
            release: { raw in
                guard let raw else { return }
                Unmanaged<Handler>.fromOpaque(raw).release()
            },
            copyDescription: nil
        )
        stream = FSEventStreamCreate(
            nil,
            { _, raw, _, _, _, _ in
                guard let raw else { return }
                let handler = Unmanaged<Handler>.fromOpaque(raw).takeUnretainedValue()
                MainActor.assumeIsolated { handler.changed() }
            },
            &context,
            paths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.35,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot)
        )
        if let stream {
            FSEventStreamSetDispatchQueue(stream, .main)
            FSEventStreamStart(stream)
        }
        withExtendedLifetime(handler) {}
    }

    deinit {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }
}
