import Foundation
@preconcurrency import CoreServices

public struct PathEvent: Sendable, Equatable {
    public let path: String
    public init(path: String) { self.path = path }
}

/// Janela de quiescência: wait() retorna `quiesce` após o último touch().
/// Genérico no clock para tornar o tempo virtual coerente em testes.
public actor Debouncer<ClockType: Clock> where ClockType.Duration == Duration {
    private let quiesce: Duration
    private let clock: ClockType
    private var lastTouch: ClockType.Instant

    public init(quiesce: Duration, clock: ClockType) {
        self.quiesce = quiesce
        self.clock = clock
        self.lastTouch = clock.now
    }

    public func touch() {
        lastTouch = clock.now
    }

    public func wait() async {
        while true {
            let elapsed = lastTouch.duration(to: clock.now)
            if elapsed >= quiesce { return }
            try? await clock.sleep(for: quiesce - elapsed)
            // acordou (deadline ou advance): recalcular — touch pode ter reiniciado a janela
        }
    }
}

/// Wrapper FSEvents: emite paths alterados sob o diretório.
public final class TranscriptWatcher: @unchecked Sendable {
    private let directory: URL
    private let latency: CFTimeInterval
    private nonisolated(unsafe) var stream: FSEventStreamRef?
    private nonisolated(unsafe) var continuation: AsyncStream<PathEvent>.Continuation?

    public init(directory: URL, latency: Double = 0.5) {
        self.directory = directory
        self.latency = latency
    }

    /// Registrar o consumidor ANTES de start() para não perder eventos iniciais.
    public func events() -> AsyncStream<PathEvent> {
        AsyncStream { continuation in
            self.continuation = continuation
        }
    }

    public func start() {
        guard stream == nil else { return }
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info, count > 0 else { return }
            let watcher = Unmanaged<TranscriptWatcher>.fromOpaque(info).takeUnretainedValue()
            let found = unsafeBitCast(paths, to: NSArray.self) as! [String]
            for path in found.prefix(Int(count)) {
                watcher.continuation?.yield(PathEvent(path: path))
            }
        }
        guard let streamRef = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            [directory.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency,
            // UseCFTypes: eventPaths chega como CFArray de CFString (cast abaixo exige isso)
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes)
        ) else { return }
        stream = streamRef
        FSEventStreamScheduleWithRunLoop(streamRef, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        FSEventStreamStart(streamRef)
    }

    public func stop() {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
        stream = nil
        continuation?.finish()
        continuation = nil
    }

    deinit { stop() }
}
