import Foundation

/// Resolves opaque IDs only inside explicitly known capture roots, without changing existing data.
/// This read-only catalog is shared-service groundwork; durable MCP operations remain separate work.
struct CaptureSessionRegistry: Sendable {
    let roots: [URL]
    static var defaultRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MobileCapture/Sessions", isDirectory: true)
    }

    private struct Metadata: Decodable {
        let id: String
        let directory: String
        let coordinator_version: Int?
    }

    func resolve(id: String) throws -> URL {
        let fileManager = FileManager.default
        var visited = Set<String>()
        var resolved: URL?
        for suppliedRoot in roots {
            let root = suppliedRoot.standardizedFileURL.resolvingSymlinksInPath()
            guard visited.insert(root.path).inserted, fileManager.fileExists(atPath: root.path) else { continue }
            let children = try fileManager.contentsOfDirectory(at: root,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles])
            guard children.count <= 10_000 else { throw AppError("This session folder is too large for session-link lookup. Use Open Session instead.") }
            for child in children {
                let values = try child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard values.isDirectory == true, values.isSymbolicLink != true,
                      child.standardizedFileURL.deletingLastPathComponent() == root else { continue }
                let metadataURL = child.appendingPathComponent("session.json")
                guard let values = try? metadataURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
                      values.isRegularFile == true, values.isSymbolicLink != true,
                      (values.fileSize ?? Int.max) <= 4 * 1024 * 1024,
                      let data = try? Data(contentsOf: metadataURL),
                      let metadata = try? JSONDecoder().decode(Metadata.self, from: data), metadata.id == id else { continue }
                guard metadata.coordinator_version == nil || metadata.coordinator_version == 1 else {
                    throw AppError("This session was created by a newer capture coordinator. Open it with a compatible app.")
                }
                let stored = URL(fileURLWithPath: metadata.directory).standardizedFileURL.resolvingSymlinksInPath()
                guard metadata.directory.hasPrefix("/"), stored == child.standardizedFileURL else {
                    throw AppError("The session's recorded location does not match its known capture folder. Use Open Session to inspect it.")
                }
                guard resolved == nil else { throw AppError("More than one known folder has this session identifier. Use Open Session to choose explicitly.") }
                resolved = child
            }
        }
        guard let resolved else { throw AppError("This capture session is not in a known session folder. Use Open Session to locate existing evidence.") }
        return resolved
    }
}
