import CryptoKit
import Darwin
import Foundation

public struct WorkerRuntime: Sendable {
    public let executable: URL
    public let resourceRoots: [URL]
    public let bundleLibraries: URL?
    public let storageRoot: URL

    public init(executable: URL, resourceRoots: [URL], bundleLibraries: URL? = nil, storageRoot: URL) {
        self.executable = executable
        self.resourceRoots = resourceRoots
        self.bundleLibraries = bundleLibraries
        self.storageRoot = storageRoot
    }

    public init(bundle: Bundle) throws {
        guard let resources = bundle.resourceURL else {
            throw EngineFailure.unavailable("The application bundle has no resource directory.")
        }
        let runtime = resources.appending(path: "OpenSCAD", directoryHint: .isDirectory)
        let root = try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil,
                                               create: false)
        self.init(
            executable: bundle.bundleURL.appending(path: "Contents/Helpers/scadretto-engine"),
            resourceRoots: [runtime],
            bundleLibraries: runtime.appending(path: "libraries", directoryHint: .isDirectory),
            storageRoot: root.appending(path: "com.lkm.Scadretto", directoryHint: .isDirectory)
        )
    }

    func identity() throws -> String {
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw EngineFailure.unavailable("The bundled OpenSCAD worker is missing or cannot be executed.")
        }
        let handle = try FileHandle(forReadingFrom: executable)
        defer { try? handle.close() }
        var hash = SHA256()
        var length = 0
        while let bytes = try handle.read(upToCount: 128 * 1024), !bytes.isEmpty {
            length += bytes.count
            guard length <= 256 * 1024 * 1024 else {
                throw EngineFailure.unavailable("The bundled OpenSCAD worker is larger than expected.")
            }
            hash.update(data: bytes)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

final class WorkerJobStore: Sendable {
    private let directory: URL
    private let home: URL
    private let fontCache: URL
    private let lease: Int32

    init(storageRoot: URL, workerBuild: String) throws {
        let manager = FileManager.default
        let sessions = storageRoot.appending(path: "sessions", directoryHint: .isDirectory)
        try Self.makePrivateDirectory(sessions)
        let registry = sessions.appending(path: "registry.lock")
        let registryFD = try Self.openLock(registry)
        defer { close(registryFD) }
        guard flock(registryFD, LOCK_EX) == 0 else { throw Self.systemError("Locking worker storage") }

        let prefix = "session-"
        for item in try manager.contentsOfDirectory(at: sessions, includingPropertiesForKeys: [.isDirectoryKey]) {
            let name = item.lastPathComponent
            guard name.hasPrefix(prefix), UUID(uuidString: String(name.dropFirst(prefix.count))) != nil,
                  try item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else { continue }
            let marker = item.appending(path: "owner.lock")
            guard let candidate = try? Self.openLock(marker) else { continue }
            if flock(candidate, LOCK_EX | LOCK_NB) == 0 {
                try? manager.removeItem(at: item)
            }
            close(candidate)
        }

        let session = sessions.appending(path: prefix + UUID().uuidString, directoryHint: .isDirectory)
        let home = session.appending(path: "home", directoryHint: .isDirectory)
        let cache = storageRoot.appending(path: "fonts-\(workerBuild)", directoryHint: .isDirectory)
        try Self.makePrivateDirectory(home)
        try Self.makePrivateDirectory(cache)
        let lease = try Self.openLock(session.appending(path: "owner.lock"))
        guard flock(lease, LOCK_EX | LOCK_NB) == 0 else {
            let error = Self.systemError("Locking the worker session")
            close(lease)
            throw error
        }
        self.directory = session
        self.home = home
        self.fontCache = cache
        self.lease = lease
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
        close(lease)
    }

    func makeJob() throws -> URL {
        let job = directory.appending(path: "job-\(UUID().uuidString)", directoryHint: .isDirectory)
        try Self.makePrivateDirectory(job)
        return job
    }

    func makeUntitledWorkspace(for id: UUID) throws -> URL {
        let workspace = directory.appending(path: "untitled-\(id.uuidString)", directoryHint: .isDirectory)
        try Self.makePrivateDirectory(workspace)
        return workspace
    }

    func environment(for job: URL, resourceRoots: [URL]) -> [String: String] {
        var environment = [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": home.path,
            "TMPDIR": job.path,
            "LANG": "en_US.UTF-8",
            "LC_CTYPE": "en_US.UTF-8",
            "LC_NUMERIC": "C",
            "XDG_CACHE_HOME": fontCache.path,
        ]
        if let resources = resourceRoots.first {
            environment["FONTCONFIG_FILE"] = resources.appending(path: "fonts/fonts.conf").path
        }
        return environment
    }

    private static func makePrivateDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
    }

    private static func openLock(_ url: URL) throws -> Int32 {
        let descriptor = open(url.path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw systemError("Opening \(url.lastPathComponent)") }
        return descriptor
    }

    private static func systemError(_ action: String) -> EngineFailure {
        let message = String(cString: strerror(errno))
        return .unavailable("\(action): \(message)")
    }
}
