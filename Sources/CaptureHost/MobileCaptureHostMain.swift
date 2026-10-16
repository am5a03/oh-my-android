import Foundation

@main
struct MobileCaptureHostMain {
    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        var directory: URL?
        do {
            guard let action = arguments.first, ["start", "stop", "stop-iphone-tunnel-off", "transfer-ca", "cancel-save", "status", "_supervise", "_worker"].contains(action), arguments.count == 3 else {
                throw AppError("Expected start --request, stop/status --session, or an internal supervisor/worker command.")
            }
            let option = arguments[1]
            let path = arguments[2]
            guard path.hasPrefix("/") else { throw AppError("Capture paths must be absolute.") }
            let url = URL(fileURLWithPath: path).standardizedFileURL
            let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
            let result: CaptureHostEnvelope
            if action == "start", option == "--request" { result = try await NativeCaptureHost.start(requestURL: url, executable: executable) }
            else if action == "_worker", option == "--config" { try CaptureHostProcesses.worker(configURL: url); return }
            else if option == "--session" {
                directory = url
                if action == "_supervise" { try await NativeCaptureHost.supervise(directory: url, executable: executable); return }
                if action == "stop" || action == "stop-iphone-tunnel-off" { result = try await NativeCaptureHost.stop(directory: url, phoneTunnelOffConfirmed: action == "stop-iphone-tunnel-off") }
                else if action == "status" { result = try NativeCaptureHost.status(directory: url) }
                else if action == "transfer-ca" { result = try await NativeCaptureHost.transferAndroidCertificate(directory: url) }
                else if action == "cancel-save" {
                    try CaptureSaveCoordinator.requestCancellation(directory: url)
                    result = CaptureHostEnvelope(session: try NativeCaptureHost.load(url))
                }
                else { throw AppError("Unsupported capture command.") }
            } else { throw AppError("Unsupported capture command arguments.") }
            try emit(result)
            if result.error != nil { exit(1) }
        } catch {
            if arguments.first?.hasPrefix("_") == true {
                FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
            } else {
                try? emit(CaptureHostEnvelope(session: directory.flatMap { try? NativeCaptureHost.load($0) }, error: error.localizedDescription))
            }
            exit(1)
        }
    }

    private static func emit(_ value: CaptureHostEnvelope) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(value); data.append(10)
        try FileHandle.standardOutput.write(contentsOf: data)
    }
}
