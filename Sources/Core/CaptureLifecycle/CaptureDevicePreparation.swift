import Darwin
import Foundation

extension NativeCaptureHost {
    /// An explicit setup action transfers only the owned session's public certificate.
    /// Trust installation remains a phone confirmation; this does not alter routing.
    static func transferAndroidCertificate(directory: URL) async throws -> CaptureHostEnvelope {
        let state = try load(directory)
        guard state.text("platform") == "android", state.text("phase") == "recording",
              state["capture_network"] == .bool(true), CaptureHostSocket.request(directory: directory, action: "ping") else {
            throw AppError("Start a network capture check for this Android device before copying its certificate.")
        }
        let request = try CaptureLifecycleFiles.read(NativeCaptureRequest.self, at: directory.appendingPathComponent("runtime/request.json"))
        guard request.platform == "android", request.device_id == state.text("device_id") else {
            throw AppError("The capture device identity changed. Start a fresh setup check.")
        }
        let discovery = NativeCaptureDiscovery()
        guard let adb = try discovery.resolve(request.adb_path, name: "adb", candidates: []) else {
            throw AppError("The bundled Android connection tool is missing. Reinstall Mobile Capture.")
        }
        let connection = try await ProcessShellRunner(timeout: .seconds(10)).run(adb, arguments: ["-s", request.device_id, "get-state"])
        guard connection.isSuccess, connection.stdout.trimmed == "device",
              CaptureHostSocket.request(directory: directory, action: "ping"),
              try load(directory).text("phase") == "recording" else {
            throw AppError("Reconnect and authorize the selected Android device, then try again.")
        }
        let files = try CaptureEvidenceFiles(directory: directory)
        guard let descriptor = try files.openRelative("setup/capture-ca-cert.pem") else {
            throw AppError("The public capture certificate is not ready yet.")
        }
        let certificate = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? certificate.close() }
        let data = try certificate.read(upToCount: 65_537) ?? Data()
        guard data.count <= 65_536, let text = String(data: data, encoding: .utf8),
              text.contains("-----BEGIN CERTIFICATE-----"), !text.contains("PRIVATE KEY") else {
            throw AppError("The public capture certificate could not be validated.")
        }
        let temporary = directory.appendingPathComponent("runtime/public-ca-\(UUID().uuidString).crt")
        try data.write(to: temporary, options: .withoutOverwriting)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
        let fingerprint = try CaptureEvidenceFiles.hash(temporary).sha256.prefix(12)
        let destination = "/sdcard/Download/mobile-capture-ca-\(fingerprint).crt"
        let result = try await ProcessShellRunner(timeout: .seconds(20)).run(adb, arguments: ["-s", request.device_id, "push", temporary.path, destination])
        guard result.isSuccess else { throw AppError("Could not copy the certificate. Reconnect the selected phone and try again.") }
        return CaptureHostEnvelope(session: try load(directory))
    }
}
