import Darwin
import Foundation

/// Exercises the real read-only Doctor against a frozen app bundle. No phone discovery,
/// pairing, installation, capture, routing or certificate-trust changes are requested.
@main
struct CaptureDoctorBundleSmoke {
    struct Failure: LocalizedError {
        let errorDescription: String?
    }

    static func main() async {
        do { try await checkBundle() }
        catch {
            FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }

    static func checkBundle() async throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard let path = arguments.first, arguments.count <= 2,
              arguments.count == 1 || arguments[1] == "--iphone-usb" else {
            throw Failure(errorDescription: "Usage: test-capture-doctor-bundle.sh /path/to/Mobile Capture.app [--iphone-usb]")
        }
        let application = URL(fileURLWithPath: path).standardizedFileURL
        guard application.pathExtension == "app", FileManager.default.fileExists(atPath: application.path) else {
            throw Failure(errorDescription: "A complete packaged app bundle is required.")
        }
        let storage = FileManager.default.temporaryDirectory
            .appendingPathComponent("capture-doctor-smoke-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: storage) }
        let doctor = CaptureDoctorService(applicationBundle: application)
        var platforms = ["android"]
        if arguments.count == 2 { platforms.append("iphone") }
        var failures: [String] = []
        for platform in platforms {
            let report = await doctor.inspect(CaptureDoctorRequest(platform: platform,
                captureLogs: platform == "iphone", captureNetwork: true, outputDirectory: storage))
            for row in report.rows {
                print("[\(platform)] \(row.title): \(row.status.rawValue)\(row.version.map { " (\($0))" } ?? "") — \(row.message)")
            }
            if !report.isReady { failures.append(platform) }
        }
        guard failures.isEmpty else {
            throw Failure(errorDescription: "Packaged Doctor rejected \(failures.joined(separator: ", ")) prerequisites. See diagnostics above.")
        }
        print("Packaged Doctor smoke passed. No devices were contacted.")
    }
}
