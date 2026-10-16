import CryptoKit
import Darwin
import Foundation

/// A setup-only handoff when recording cannot start. It reads no session or runtime files.
nonisolated struct CaptureReadinessExport: Sendable {
    @concurrent
    static func export(report: CaptureSetupReport, plan: CapturePlan? = nil, to destination: URL) async throws -> URL {
        _ = try plan?.validated()
        try Task.checkCancellation()
        guard destination.isFileURL, destination.path.hasPrefix("/"), destination.pathExtension.lowercased() == "zip" else {
            throw AppError("Choose a ZIP file for the setup report.")
        }
        try validateDestination(destination)
        let work = destination.deletingLastPathComponent().appendingPathComponent(".capture-setup-report-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: work) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let payload = Payload(report: report, capturePlan: plan)
        let data = try encoder.encode(payload)
        guard data.count <= 256 * 1024 else { throw AppError("The setup diagnostic report exceeds its size limit.") }
        let summary = (["Mobile Capture setup diagnostics", "", "No device recording is included in this package.",
                        "App: \(report.identity.applicationID ?? "Not selected")", "Platform: \(report.identity.platform ?? "Not selected")",
                        "Task: \(plan?.title ?? "Manual capture")", "", "Setup checks:"]
            + report.checks.map { "- \($0.title): \($0.state.rawValue) [\($0.code)]\n  \($0.message)" }
            + ["", "Ready-to-try checks describe prerequisites. Only observed evidence verifies capture.",
               "This report contains public configuration identities and setup results, without capture bodies, private keys, tunnel profiles or runtime files.",
               "Saved locally. Review before sharing with your engineer.", ""]).joined(separator: "\n")
        let files = ["setup-report.json": data, "ENGINEER-SUMMARY.txt": Data(summary.utf8)]
        var checksums = ""
        for (name, bytes) in files.sorted(by: { $0.key < $1.key }) {
            try bytes.write(to: work.appendingPathComponent(name), options: .withoutOverwriting)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: work.appendingPathComponent(name).path)
            checksums += SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() + "  " + name + "\n"
        }
        try Data(checksums.utf8).write(to: work.appendingPathComponent("SHA256SUMS"), options: .withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: work.appendingPathComponent("SHA256SUMS").path)
        let archive = work.appendingPathComponent("setup-diagnostics.zip")
        let members = (Array(files.keys) + ["SHA256SUMS"]).sorted().map { work.appendingPathComponent($0).path }
        let result = try await ProcessShellRunner(timeout: .seconds(30)).run(URL(fileURLWithPath: "/usr/bin/zip"),
            arguments: ["-X", "-q", "-j", archive.path, "--"] + members)
        guard result.isSuccess else { throw AppError("The setup report could not be packaged. Choose another destination and try again.") }
        try Task.checkCancellation()
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: archive.path)
        try validateDestination(destination)
        guard rename(archive.path, destination.path) == 0 else { throw AppError("The setup ZIP could not be saved. Choose another destination and try again.") }
        return destination
    }

    private struct Payload: Encodable {
        let format = "mobile-capture-setup-diagnostics"
        let schemaVersion = 1
        let report: CaptureSetupReport
        let capturePlan: CapturePlan?
    }

    private static func validateDestination(_ destination: URL) throws {
        var info = stat()
        if lstat(destination.path, &info) == 0 {
            guard info.st_mode & S_IFMT == S_IFREG, info.st_uid == geteuid() else {
                throw AppError("Choose a regular ZIP destination, not a linked file or folder.")
            }
        } else if errno != ENOENT { throw AppError("The setup report destination is not accessible.") }
    }
}
