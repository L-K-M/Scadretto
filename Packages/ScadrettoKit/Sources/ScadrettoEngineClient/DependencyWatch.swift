import CryptoKit
import Darwin
import Foundation
import os

/// Watches both a file and its containing directory so atomic replacements
/// and the creation of formerly missing lookup candidates are visible.
public final class DependencyWatch: Sendable {
    private struct Watch: Sendable {
        let device: dev_t
        let inode: ino_t
        let source: any DispatchSourceFileSystemObject

        func stillWatches(_ url: URL) -> Bool {
            var info = stat()
            return stat(url.path, &info) == 0 && info.st_dev == device && info.st_ino == inode
        }
    }

    private let files: [FileRecord]
    private let lookups: [LookupRecord]
    private let paths: Set<URL>
    private let onChange: @Sendable () -> Void
    private let watches = OSAllocatedUnfairLock(initialState: [URL: Watch]())

    public init(result: EvaluationResult, onChange: @escaping @Sendable () -> Void) {
        files = result.files.filter { $0.kind != .main }
        lookups = result.lookups
        var paths = Set(files.flatMap { file in
            [file.logicalPath, file.resolvedPath].compactMap { $0 }
        })
        for lookup in lookups { paths.formUnion(lookup.candidates) }
        self.paths = Set(paths.map { URL(fileURLWithPath: $0).standardizedFileURL })
        self.onChange = onChange
        refreshWatches()
    }

    private func refreshWatches() {
        watches.withLock { active in
            var needed: Set<URL> = []
            for url in paths {
                if Self.regularFile(url) { needed.insert(url) }
                if let ancestor = Self.existingAncestor(of: url) { needed.insert(ancestor) }
            }
            var next: [URL: Watch] = [:]
            for url in needed {
                if let watch = active[url], watch.stillWatches(url) {
                    next[url] = active.removeValue(forKey: url)
                } else {
                    next[url] = startWatch(at: url)
                }
            }
            for watch in active.values { watch.source.cancel() }
            active = next
        }
    }

    private func startWatch(at url: URL) -> Watch? {
        let fd = open(url.path, O_EVTONLY | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        var info = stat()
        guard fstat(fd, &info) == 0 else {
            close(fd)
            return nil
        }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .delete, .rename, .extend, .attrib, .revoke],
            queue: DispatchQueue.global(qos: .utility)
        )
        source.setEventHandler(handler: onChange)
        source.setCancelHandler { close(fd) }
        source.activate()
        return Watch(device: info.st_dev, inode: info.st_ino, source: source)
    }

    deinit {
        watches.withLock { active in
            for watch in active.values { watch.source.cancel() }
        }
    }

    /// Recheck content and path identity off the main actor before presenting
    /// a result and after directory notifications.
    public func isCurrent() -> Bool {
        // A directory can appear without changing the lookup winner yet.
        // Follow it before checking the paths so the next creation is visible.
        refreshWatches()
        for file in files {
            let url = URL(fileURLWithPath: file.resolvedPath ?? file.logicalPath)
            guard let digest = try? Self.coordinatedDigest(url, expectedLength: file.byteLength),
                  digest == file.sha256 else { return false }
        }
        for lookup in lookups {
            let winner = lookup.candidates.first { Self.regularFile(URL(fileURLWithPath: $0)) }
            guard winner == lookup.winner else { return false }
            if let winner, let expected = lookup.resolvedWinner {
                let resolved = URL(fileURLWithPath: winner).resolvingSymlinksInPath().standardizedFileURL.path
                guard resolved == expected else { return false }
            }
        }
        return true
    }

    private static func regularFile(_ url: URL) -> Bool {
        var value = stat()
        return stat(url.path, &value) == 0 && (value.st_mode & S_IFMT) == S_IFREG
    }

    private static func existingAncestor(of url: URL) -> URL? {
        var candidate = url.deletingLastPathComponent()
        while true {
            var value = stat()
            if stat(candidate.path, &value) == 0 && (value.st_mode & S_IFMT) == S_IFDIR { return candidate }
            let parent = candidate.deletingLastPathComponent()
            if parent == candidate { return nil }
            candidate = parent
        }
    }

    private static func coordinatedDigest(_ url: URL, expectedLength: UInt64) throws -> String {
        let coordinator = NSFileCoordinator()
        var coordinationError: NSError?
        var outcome: Result<String, any Error>?
        coordinator.coordinate(readingItemAt: url, options: [.withoutChanges], error: &coordinationError) { local in
            outcome = Result { try digest(local, expectedLength: expectedLength) }
        }
        if let coordinationError { throw coordinationError }
        guard let outcome else { throw CocoaError(.fileReadUnknown) }
        return try outcome.get()
    }

    private static func digest(_ url: URL, expectedLength: UInt64) throws -> String {
        let fd = open(url.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw CocoaError(.fileReadNoSuchFile) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_size >= 0,
              UInt64(info.st_size) == expectedLength else {
            throw CocoaError(.fileReadCorruptFile)
        }
        var hash = SHA256()
        var count: UInt64 = 0
        while let data = try handle.read(upToCount: 128 * 1024), !data.isEmpty {
            count += UInt64(data.count)
            guard count <= expectedLength else { throw CocoaError(.fileReadCorruptFile) }
            hash.update(data: data)
        }
        guard count == expectedLength else { throw CocoaError(.fileReadCorruptFile) }
        return hash.finalize().hexString
    }
}
