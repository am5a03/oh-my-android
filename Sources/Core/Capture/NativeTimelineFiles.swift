import Darwin
import Foundation

/// Immutable descriptor ownership. All reads use pread; no shared seek position or mutable Swift state.
final class NativeTimelineFile: @unchecked Sendable {
    let descriptor: Int32
    init(_ descriptor: Int32) { self.descriptor = descriptor }
    deinit { Darwin.close(descriptor) }

    func information() throws -> stat {
        var value = stat()
        guard fstat(descriptor, &value) == 0 else { throw NativeTimelineFiles.failure("Inspect evidence") }
        return value
    }

    func read(offset: Int64, count: Int) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        let amount = bytes.withUnsafeMutableBytes { pread(descriptor, $0.baseAddress, count, off_t(offset)) }
        guard amount >= 0 else { throw NativeTimelineFiles.failure("Read evidence") }
        return Data(bytes.prefix(amount))
    }
}

/// An open root descriptor prevents parent-path replacement from redirecting evidence reads/writes.
final class NativeTimelineFiles: @unchecked Sendable {
    let root: NativeTimelineFile
    let cache: NativeTimelineFile

    init(directory: URL) throws {
        guard directory.isFileURL, !directory.path.contains("\0") else { throw NativeTimelineError.message("Choose a local capture session directory.") }
        let path = directory.path
        let fd = Darwin.open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw Self.failure("Open capture session without symlinks") }
        let root = NativeTimelineFile(fd)
        self.root = root
        let runtime = try Self.directory("runtime", in: root, create: true)
        cache = try Self.directory("native-timeline", in: runtime, create: true, privateOwner: true)
    }

    static func failure(_ operation: String) -> NativeTimelineError {
        .message("\(operation): \(String(cString: strerror(errno))). Evidence paths must be ordinary files/directories without symlinks.")
    }

    static func directory(_ name: String, in parent: NativeTimelineFile, create: Bool, privateOwner: Bool = false) throws -> NativeTimelineFile {
        if create, mkdirat(parent.descriptor, name, 0o700) != 0, errno != EEXIST { throw failure("Create private timeline directory") }
        let fd = openat(parent.descriptor, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw failure("Open timeline directory") }
        let result = NativeTimelineFile(fd), info = try result.information()
        if privateOwner, info.st_uid != getuid() || info.st_mode & 0o077 != 0 {
            throw NativeTimelineError.message("The timeline cache must belong to this user and have private (700) directory permissions.")
        }
        return result
    }

    func evidence(_ relative: String) throws -> NativeTimelineFile? {
        let parts = relative.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !relative.hasPrefix("/"), !parts.isEmpty, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\0") }) else {
            throw NativeTimelineError.message("Evidence paths must stay inside the capture session.")
        }
        var parent = root
        do {
            for component in parts.dropLast() { parent = try Self.directory(component, in: parent, create: false) }
        } catch {
            if errno == ENOENT { return nil }
            throw error
        }
        let fd = openat(parent.descriptor, parts.last!, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if fd < 0, errno == ENOENT { return nil }
        guard fd >= 0 else { throw Self.failure("Open \(relative)") }
        let file = NativeTimelineFile(fd)
        guard try file.information().st_mode & S_IFMT == S_IFREG else {
            throw NativeTimelineError.message("Evidence is not a regular file: \(relative)")
        }
        return file
    }

    func read(_ relative: String, maximum: Int = 4 * 1024 * 1024) throws -> Data? {
        guard let file = try evidence(relative) else { return nil }
        let size = try file.information().st_size
        guard size <= maximum else { throw NativeTimelineError.message("Capture metadata is unexpectedly large: \(relative)") }
        return try file.read(offset: 0, count: Int(size))
    }

    func databasePath() throws -> String {
        // A new schema gets a new filename. Never migrate, unlink or rename a legacy
        // database that another process may still have open.
        let name = "compact-v3.sqlite"
        let fd = openat(cache.descriptor, name, O_RDWR | O_CREAT | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw Self.failure("Open private timeline index") }
        let file = NativeTimelineFile(fd), info = try file.information()
        guard info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(), info.st_mode & 0o077 == 0 else {
            throw NativeTimelineError.message("The timeline index must be a private regular file owned by this user.")
        }
        // SQLite's VFS cannot open children of /dev/fd on macOS. Resolve the already-open
        // private directory with F_GETPATH, never by following user-supplied symlink paths.
        // The database is precreated 600 and SQLite also opens it with NOFOLLOW.
        for name in [name + "-journal", name + "-wal", name + "-shm"] {
            var status = stat()
            if fstatat(cache.descriptor, name, &status, AT_SYMLINK_NOFOLLOW) == 0,
               status.st_mode & S_IFMT != S_IFREG || status.st_uid != getuid() || status.st_mode & 0o077 != 0 {
                throw NativeTimelineError.message("Unsafe timeline index sidecar: \(name)")
            }
        }
        var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(cache.descriptor, F_GETPATH, &path) == 0 else { throw Self.failure("Resolve private timeline cache") }
        return String(decoding: path.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self) + "/" + name
    }

    func appendMarker(_ data: Data) throws {
        let timeline = try Self.directory("timeline", in: root, create: true)
        let fd = openat(timeline.descriptor, "markers.jsonl", O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw Self.failure("Append marker") }
        let file = NativeTimelineFile(fd)
        guard try file.information().st_mode & S_IFMT == S_IFREG else { throw NativeTimelineError.message("Marker evidence is not a regular file.") }
        let count = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
        guard count == data.count, fsync(fd) == 0 else { throw Self.failure("Write complete marker") }
    }

    static func atomicFile(at destination: URL, write: (NativeTimelineFile) throws -> Void) throws {
        guard destination.isFileURL else { throw NativeTimelineError.message("Timeline export needs a local file.") }
        let parentURL = destination.deletingLastPathComponent().resolvingSymlinksInPath()
        let fd = Darwin.open(parentURL.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw failure("Open timeline export directory") }
        let parent = NativeTimelineFile(fd), name = destination.lastPathComponent
        guard !name.isEmpty, name != ".", name != "..", !name.contains("\0") else { throw NativeTimelineError.message("Choose an ordinary timeline export filename.") }
        var info = stat()
        if fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0, info.st_mode & S_IFMT != S_IFREG {
            throw NativeTimelineError.message("Timeline export destination must not be a symlink or special file.")
        }
        let temporary = ".native-timeline-\(UUID().uuidString).tmp"
        let output = openat(fd, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard output >= 0 else { throw failure("Create timeline export") }
        let file = NativeTimelineFile(output)
        defer { unlinkat(parent.descriptor, temporary, 0) }
        try write(file)
        guard fsync(output) == 0, renameat(fd, temporary, fd, name) == 0 else { throw failure("Publish timeline export") }
    }

    static func writeAll(_ data: Data, to file: NativeTimelineFile) throws {
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let amount = Darwin.write(file.descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if amount < 0, errno == EINTR { continue }
                guard amount > 0 else { throw failure("Write timeline export") }
                offset += amount
            }
        }
    }
}
