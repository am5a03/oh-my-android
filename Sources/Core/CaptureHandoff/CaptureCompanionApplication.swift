import Foundation

/// App metadata is compatibility information, not authentication for capture control.
struct CaptureCompanionApplication: Sendable {
    let url: URL
    let bundleIdentifier: String
    let handoffVersions: [Int]
    var supportsContext: Bool { handoffVersions.contains(CaptureHandoff.version) }

    init(url: URL) throws {
        let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
        guard resolved.pathExtension.lowercased() == "app", let bundle = Bundle(url: resolved),
              bundle.object(forInfoDictionaryKey: CaptureAppIdentity.productMetadataKey) as? Bool == true,
              let identifier = bundle.bundleIdentifier, !identifier.isEmpty,
              let executable = bundle.executableURL,
              executable.standardizedFileURL.resolvingSymlinksInPath().path.hasPrefix(resolved.path + "/Contents/MacOS/"),
              FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw AppError("Choose a Mobile Capture companion application. This bundle is missing its companion metadata or executable.")
        }
        self.url = resolved
        bundleIdentifier = identifier
        handoffVersions = bundle.object(forInfoDictionaryKey: CaptureAppIdentity.versionsMetadataKey) as? [Int] ?? []
    }
}
