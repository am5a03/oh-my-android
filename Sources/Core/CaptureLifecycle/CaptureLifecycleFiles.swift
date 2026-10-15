import Darwin
import Foundation

enum CaptureLifecycleFiles {
    static func timestamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: Date())
    }

    static func privateDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == geteuid(), info.st_mode & 0o077 == 0 else {
            throw AppError("Capture directory has unsafe ownership or permissions: \(url.lastPathComponent)")
        }
    }

    static func read<T: Decodable>(_ type: T.Type, at url: URL) throws -> T {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw AppError("Cannot read capture state: \(url.lastPathComponent)") }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == geteuid() else { throw AppError("Capture state must be a regular owned file.") }
        return try JSONDecoder().decode(type, from: handle.readToEnd() ?? Data())
    }

    static func write<T: Encodable>(_ value: T, at url: URL) throws {
        try privateDirectory(url.deletingLastPathComponent())
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent)-\(UUID().uuidString).tmp")
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw AppError("Cannot create private capture state.") }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close(); try? FileManager.default.removeItem(at: temporary) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        try handle.write(contentsOf: encoder.encode(value))
        try handle.synchronize()
        guard rename(temporary.path, url.path) == 0 else { throw AppError("Cannot publish capture state.") }
        let parent = open(url.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        if parent >= 0 { _ = fsync(parent); close(parent) }
    }
}

/// Holds the same cross-output-root lock as the legacy runtime. No PID is read or signalled.
final class CaptureRoutingLease {
    private let descriptor: Int32

    init(sessionDirectory: URL, lockDirectory: URL? = nil) throws {
        let root = lockDirectory ?? URL(fileURLWithPath: "/tmp/capture-companion-\(getuid())", isDirectory: true)
        try CaptureLifecycleFiles.privateDirectory(root)
        let file = root.appendingPathComponent("owner.lock")
        let fd = open(file.path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw AppError("Cannot open the private capture ownership lock.") }
        var accepted = false
        defer { if !accepted { close(fd) } }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == geteuid(),
              info.st_mode & 0o022 == 0, info.st_nlink == 1 else { throw AppError("Capture ownership lock has unsafe permissions.") }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw AppError("Another capture owns the connection. Stop it before starting another.") }
        // Legacy Python created mode-644 locks inside this verified mode-700 directory.
        // Reuse their inode so native and legacy hosts still exclude one another.
        guard fchmod(fd, 0o600) == 0 else { throw AppError("Cannot secure capture ownership lock.") }
        let existing = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        let prior = String(decoding: try existing.readToEnd() ?? Data(), as: UTF8.self).trimmed
        if !prior.isEmpty, URL(fileURLWithPath: prior).standardizedFileURL != sessionDirectory.standardizedFileURL {
            struct Prior: Decodable { let phase: String; let routing_restored: Bool? }
            let stateURL = URL(fileURLWithPath: prior).appendingPathComponent("session.json")
            if FileManager.default.fileExists(atPath: stateURL.path) {
                let state = try CaptureLifecycleFiles.read(Prior.self, at: stateURL)
                guard !["preparing", "recording", "stopping"].contains(state.phase), state.routing_restored != false else {
                    throw AppError("A previous capture needs recovery. Open it and use Restore Connection & Save: \(prior)")
                }
            }
        }
        try existing.seek(toOffset: 0)
        try existing.truncate(atOffset: 0)
        try existing.write(contentsOf: Data(sessionDirectory.path.utf8))
        try existing.synchronize()
        descriptor = fd
        accepted = true
    }

    deinit { close(descriptor) }
}
