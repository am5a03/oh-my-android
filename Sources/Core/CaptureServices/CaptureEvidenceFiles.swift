import CryptoKit
import Darwin
import Foundation

/// An anchored directory descriptor prevents evidence reads from following replaced symlinks.
/// This type owns descriptors, so it remains local to one export operation.
nonisolated final class CaptureEvidenceFiles {
    let directory: URL
    private let descriptor: Int32

    init(directory: URL) throws {
        let input = directory.standardizedFileURL
        var info = stat()
        guard lstat(input.path, &info) == 0, (info.st_mode & S_IFMT) != S_IFLNK else {
            throw AppError("The session directory must exist and must not be a symlink.")
        }
        // Resolve system aliases in ancestors (for example /var -> /private/var),
        // but never resolve the caller's final session component before O_NOFOLLOW.
        self.directory = input.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent(input.lastPathComponent)
        descriptor = Darwin.open(self.directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw Self.failure("Open session directory") }
    }

    deinit { Darwin.close(descriptor) }

    func openRelative(_ relative: String) throws -> Int32? {
        let parts = relative.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !parts.isEmpty, !relative.hasPrefix("/"), parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\0") }) else {
            throw AppError("Evidence paths must be relative to the session.")
        }
        var parent = dup(descriptor)
        guard parent >= 0 else { throw Self.failure("Open evidence directory") }
        defer { Darwin.close(parent) }
        for part in parts.dropLast() {
            let next = openat(parent, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            if next < 0 {
                if errno == ENOENT { return nil }
                throw Self.failure("Open evidence directory \(relative)")
            }
            Darwin.close(parent)
            parent = next
        }
        guard let name = parts.last else { throw AppError("An evidence filename is required.") }
        let file = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if file < 0 {
            if errno == ENOENT { return nil }
            throw Self.failure("Open evidence \(relative)")
        }
        var info = stat()
        guard fstat(file, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            Darwin.close(file)
            throw AppError("Evidence must be a regular file: \(relative)")
        }
        return file
    }

    /// Streams original bytes into a private stage, hashing the same bytes that enter the ZIP.
    func copy(_ relative: String, to destination: URL) throws -> CaptureEvidenceArtifact? {
        guard let source = try openRelative(relative) else { return nil }
        defer { Darwin.close(source) }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let output = Darwin.open(destination.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard output >= 0 else { throw Self.failure("Create private evidence copy") }
        defer { Darwin.close(output) }
        var hash = SHA256()
        var bytes: Int64 = 0
        let recordsLines = relative == "logs/device.log" || relative.hasSuffix(".jsonl")
        var newlines = 0
        var previousCR = false
        var lastByte: UInt8? = nil
        var buffer = [UInt8](repeating: 0, count: 1024 * 1024)
        while true {
            try Task.checkCancellation()
            let count = Darwin.read(source, &buffer, buffer.count)
            if count < 0 {
                if errno == EINTR { continue }
                throw Self.failure("Read original evidence")
            }
            if count == 0 { break }
            let chunk = Data(buffer.prefix(count))
            hash.update(data: chunk)
            try Self.write(chunk, descriptor: output)
            bytes += Int64(count)
            if recordsLines {
                for byte in chunk {
                    if byte == 13 { newlines += 1; previousCR = true }
                    else {
                        if byte == 10, !previousCR { newlines += 1 }
                        previousCR = false
                    }
                }
                lastByte = chunk.last
            }
        }
        guard fsync(output) == 0 else { throw Self.failure("Save evidence copy") }
        let lineCount = recordsLines ? newlines + (lastByte != nil && lastByte != 10 && lastByte != 13 ? 1 : 0) : nil
        return CaptureEvidenceArtifact(path: relative, bytes: bytes, sha256: Self.hex(hash.finalize()), lineCount: lineCount)
    }

    func publish(archive: URL) throws -> URL {
        var existing = stat()
        let name = "capture-package.zip"
        if fstatat(descriptor, name, &existing, AT_SYMLINK_NOFOLLOW) == 0 {
            guard (existing.st_mode & S_IFMT) == S_IFREG else {
                throw AppError("The package destination must be a regular file, not a symlink or directory.")
            }
        } else if errno != ENOENT { throw Self.failure("Inspect package destination") }
        let input = Darwin.open(archive.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard input >= 0 else { throw Self.failure("Open finished package") }
        defer { Darwin.close(input) }
        guard fchmod(input, 0o600) == 0, fsync(input) == 0 else { throw Self.failure("Save finished package") }
        // renameat replaces the destination directory entry itself; it never follows its target.
        guard renameat(AT_FDCWD, archive.path, descriptor, name) == 0 else { throw Self.failure("Publish capture package") }
        guard fsync(descriptor) == 0 else { throw Self.failure("Save package directory") }
        return directory.appendingPathComponent(name)
    }

    static func write(_ data: Data, descriptor: Int32) throws {
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 {
                    if errno == EINTR { continue }
                    throw failure("Write evidence")
                }
                guard count > 0 else { throw AppError("Could not write the complete evidence file.") }
                offset += count
            }
        }
    }

    static func hash(_ url: URL) throws -> (bytes: Int64, sha256: String) {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        var bytes: Int64 = 0
        while let chunk = try autoreleasepool(invoking: { try handle.read(upToCount: 1024 * 1024) }), !chunk.isEmpty {
            try Task.checkCancellation()
            hash.update(data: chunk)
            bytes += Int64(chunk.count)
        }
        return (bytes, hex(hash.finalize()))
    }

    private static func hex(_ digest: SHA256.Digest) -> String { digest.map { String(format: "%02x", $0) }.joined() }
    private static func failure(_ operation: String) -> AppError { AppError("\(operation): \(String(cString: strerror(errno)))") }
}

nonisolated struct CaptureEvidenceArtifact: Sendable, Equatable {
    let path: String
    let bytes: Int64
    let sha256: String
    let lineCount: Int?
}
