import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Cooperating desktop/MCP processes use the same advisory lock. Busy calls fail rather than
/// queueing a destructive operation against a target whose state may change while waiting.
/// This does not sandbox another process running as the same macOS user, or third-party adb.
enum DeviceOperationLock {
    @TaskLocal private static var heldKeys: Set<String> = []

    static func withLock<T: Sendable>(
        _ key: String, directory: URL? = nil,
        _ work: @Sendable () async throws -> T
    ) async throws -> T {
        try Task.checkCancellation()
        if heldKeys.contains(key) { return try await work() }
        let root = directory ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/se.royan.ohmyandroid/DeviceLocks", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        // Stable, non-secret filename. A hash collision only conservatively blocks an unrelated call.
        let hash = key.utf8.reduce(UInt64(14695981039346656037)) { ($0 ^ UInt64($1)) &* 1099511628211 }
        let path = root.appendingPathComponent(String(hash, radix: 16) + ".lock").path
        let descriptor = open(path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard descriptor >= 0 else { throw AppError("Could not open the device operation lock.") }
        defer { _ = close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_uid == getuid(),
              (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else {
            throw AppError("Device operation lock is not a regular file owned by this user.")
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            throw AppError("Another companion or MCP operation is using this device. Retry after it finishes.")
        }
        defer { _ = flock(descriptor, LOCK_UN) }
        try Task.checkCancellation()
        return try await $heldKeys.withValue(heldKeys.union([key])) { try await work() }
    }
}
