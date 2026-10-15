import CryptoKit
import Foundation

/// A private fixed-width disk index validates arbitrary chronological references in O(1) memory.
/// It hashes staged original bytes, so a stale normalized index cannot silently describe changed raw files.
nonisolated final class CaptureEvidenceReferences {
    private struct Source {
        let name: String
        let handle: FileHandle
        let lines: Int
    }
    private var sources: [String: Source] = [:]
    private var expectedEvents = 0
    private var validatedEvents = 0
    private static let width = 13 // nonblank flag plus the schema's first 12 SHA256 bytes

    var lineCounts: [String: Int] { sources.mapValues(\.lines) }

    init(stage: URL, scratch: URL) throws {
        do {
            for (source, path) in [("logs", "logs/device.log"), ("network", "network/events.jsonl"), ("marker", "timeline/markers.jsonl")] {
                let original = stage.appendingPathComponent(path)
                guard FileManager.default.fileExists(atPath: original.path) else { continue }
                let index = scratch.appendingPathComponent(".references-\(source)")
                try Data().write(to: index, options: .withoutOverwriting)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: index.path)
                let writer = try FileHandle(forWritingTo: index)
                let records: (lines: Int, events: Int)
                do { records = try Self.build(original, output: writer, source: source, path: path); try writer.close() }
                catch { try? writer.close(); throw error }
                sources[path] = Source(name: source, handle: try FileHandle(forUpdating: index), lines: records.lines)
                expectedEvents += records.events
            }
        } catch {
            for source in sources.values { try? source.handle.close() }
            throw error
        }
    }

    deinit { for source in sources.values { try? source.handle.close() } }

    func validate(id: String, source: String, path: String, line: Int) throws {
        guard let original = sources[path], original.name == source, line > 0, line <= original.lines else {
            throw AppError("The normalized timeline refers to an unavailable raw evidence record.")
        }
        try original.handle.seek(toOffset: UInt64(line - 1) * UInt64(Self.width))
        guard let bytes = try original.handle.read(upToCount: Self.width), bytes.count == Self.width, bytes.first == 1 else {
            throw AppError("The normalized timeline refers to a blank or unreadable raw evidence line.")
        }
        let alphabet = Array("0123456789abcdef".utf8)
        var identifier = Array("event-".utf8)
        identifier.reserveCapacity(30)
        for byte in bytes.dropFirst() {
            identifier.append(alphabet[Int(byte >> 4)])
            identifier.append(alphabet[Int(byte & 15)])
        }
        let expected = String(decoding: identifier, as: UTF8.self)
        guard id == expected else {
            throw AppError("Raw evidence changed after the timeline was indexed. Refresh the session and retry Save; the prior ZIP was preserved.")
        }
        try original.handle.seek(toOffset: UInt64(line - 1) * UInt64(Self.width))
        try original.handle.write(contentsOf: Data([2]))
        validatedEvents += 1
    }

    func validateComplete() throws {
        guard validatedEvents == expectedEvents else {
            throw AppError("The normalized timeline omits captured raw evidence. Refresh the complete session and retry Save; the prior ZIP was preserved.")
        }
    }

    private static func build(_ original: URL, output: FileHandle, source: String, path: String) throws -> (lines: Int, events: Int) {
        let input = try FileHandle(forReadingFrom: original)
        defer { try? input.close() }
        var buffer = Data(), scan = 0, line = 0, events = 0
        var records = Data()
        records.reserveCapacity(512 * 1024)
        func writeRecord(_ raw: Data) throws {
            line += 1
            var hash = SHA256()
            hash.update(data: Data("\(source)\0\(path)\0\(line)\0".utf8))
            hash.update(data: raw)
            let nonblank = raw.contains(where: { ![9, 10, 11, 12, 13, 32].contains($0) })
            if nonblank { events += 1 }
            records.append(nonblank ? 1 : 0)
            records.append(contentsOf: hash.finalize().prefix(12))
            if records.count >= 512 * 1024 {
                try output.write(contentsOf: records)
                records.removeAll(keepingCapacity: true)
            }
        }
        while let chunk = try autoreleasepool(invoking: { try input.read(upToCount: 1024 * 1024) }), !chunk.isEmpty {
            try Task.checkCancellation()
            buffer.append(chunk)
            var start = 0, ranges: [Range<Int>] = []
            buffer.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
                while scan < bytes.count {
                    if bytes[scan] == 13, scan + 1 == bytes.count { break }
                    if bytes[scan] == 10 || bytes[scan] == 13 {
                        ranges.append(start..<scan)
                        scan += bytes[scan] == 13 && scan + 1 < bytes.count && bytes[scan + 1] == 10 ? 2 : 1
                        start = scan
                    } else { scan += 1 }
                }
            }
            for range in ranges { try autoreleasepool { try writeRecord(buffer.subdata(in: range)) } }
            if start > 0 { buffer.removeSubrange(0..<start); scan -= start }
        }
        if !buffer.isEmpty {
            if buffer.last == 13 { buffer.removeLast() }
            try writeRecord(buffer)
        }
        if !records.isEmpty { try output.write(contentsOf: records) }
        return (line, events)
    }
}
