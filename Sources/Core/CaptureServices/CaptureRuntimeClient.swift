import Foundation

struct CaptureUpdate: Decodable, Sendable {
    let session: CaptureSession
}

/// A failed operation can still own a session that needs Stop to restore routing.
struct CaptureRuntimeFailure: Decodable, LocalizedError, Sendable {
    let error: String
    let session: CaptureSession?
    var errorDescription: String? { error }
}

struct CaptureStartRequest: Encodable, Sendable {
    let platform: String
    let deviceId: String
    let deviceName: String
    let captureLogs: Bool
    let captureNetwork: Bool
    let outputRoot: String
    let targetApp: String?
    let networkService: String?
    let trustSimulatorCa: Bool
    let adbPath: String?
    let mitmdumpPath: String?
    let proxyHelperPath: String?
    let runtimeDirectory: String?
    let iphoneEndpointHost: String?
    let loggingPolicy: CaptureLoggingPolicy?
    let logScope: CaptureLogScope?
    var setupContext: CaptureSessionSetupContext? = nil
}

/// The app talks to a compiled sibling helper. JSON carries session metadata, never captured bodies.
struct CaptureRuntimeClient: Sendable {
    let executableOverride: URL?

    func executable() throws -> URL {
        let sibling = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("mobile-capture-host")
        guard let executable = executableOverride ?? sibling,
              executable.path.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw AppError("The compiled capture service is missing. Rebuild or reinstall the app with mobile-capture-host embedded.")
        }
        return executable
    }

    var isAvailable: Bool { (try? executable()) != nil }

    func call<T: Decodable & Sendable>(_ arguments: [String], timeout: Duration = .seconds(30)) async throws -> T {
        let output = try await ProcessShellRunner(timeout: timeout).run(executable(), arguments: arguments)
        let data = Data(output.stdout.utf8)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        if output.exitCode != 0 {
            if let failure = try? decoder.decode(CaptureRuntimeFailure.self, from: data) { throw failure }
            throw AppError(output.stderr.trimmed.isEmpty ? "Capture service failed (exit \(output.exitCode))." : output.stderr.trimmed)
        }
        do { return try decoder.decode(T.self, from: data) }
        catch { throw AppError("The capture service returned an unreadable response: \(error.localizedDescription)") }
    }
}

