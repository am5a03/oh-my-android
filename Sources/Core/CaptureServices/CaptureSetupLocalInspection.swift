import CryptoKit
import Darwin
import Foundation
import Security

/// Bounded read-only inspection. Unlike profile preparation helpers, these reads never chmod,
/// create, repair, delete or lock a file for writing.
nonisolated struct CaptureSetupLocalInspection: Sendable {
    let applicationBundle: URL?
    let caDirectory: URL
    let iphoneProfileRoot: URL
    let routingLockDirectory: URL
    var availableDiskBytes: (@Sendable (URL) -> Int64?)? = nil
    static var defaultRoutingDirectory: URL { URL(fileURLWithPath: "/tmp/capture-companion-\(getuid())", isDirectory: true) }

    struct Result: Sendable {
        let state: CaptureSetupState
        let message: String
        let code: String
        var fingerprint: String? = nil
        var endpoint: String? = nil
    }

    func publicCertificate() -> Result {
        do {
            let file = caDirectory.appendingPathComponent("mitmproxy-ca-cert.pem")
            guard let data = try read(file, maximum: 65_536, privateFile: false), let text = String(data: data, encoding: .utf8),
                  let begin = text.range(of: "-----BEGIN CERTIFICATE-----"),
                  let end = text.range(of: "-----END CERTIFICATE-----", range: begin.upperBound..<text.endIndex) else {
                return Result(state: .actionNeeded, message: "Prepare this Mac's stable capture certificate. An older certificate also named mitmproxy may belong to a different tool.", code: "public_ca_missing")
            }
            let body = text[begin.upperBound..<end.lowerBound].filter { !$0.isWhitespace }
            guard let der = Data(base64Encoded: String(body)), SecCertificateCreateWithData(nil, der as CFData) != nil else {
                return Result(state: .needsEngineerHelp, message: "The saved public capture certificate cannot be parsed. Ask an engineer to inspect this Mac's existing CA; it has not been replaced.", code: "public_ca_unreadable")
            }
            return Result(state: .readyToTry,
                message: "This Mac's public capture certificate is present. Its fingerprint identifies the certificate; installation/full trust and HTTPS behavior on the device remain unverified.",
                code: "public_ca_present", fingerprint: Self.digest(der))
        } catch {
            return Result(state: .needsEngineerHelp, message: "The saved public certificate could not be inspected safely. Existing CA files and keys have not been changed.", code: "public_ca_unsafe")
        }
    }

    func iphoneProfile(deviceID: String?) -> Result {
        guard let deviceID, !deviceID.isEmpty else { return Result(state: .actionNeeded, message: "Select the iPhone before preparing its tunnel.", code: "profile_device_missing") }
        let directory = iphoneProfileRoot.appendingPathComponent(Self.digest(Data(deviceID.utf8)), isDirectory: true)
        do {
            guard try privateDirectoryExists(iphoneProfileRoot), try privateDirectoryExists(directory),
                  let data = try read(directory.appendingPathComponent("MobileCapture.conf"), maximum: 65_536, privateFile: true),
                  try privateRegularFileExists(directory.appendingPathComponent("server.json")),
                  let text = String(data: data, encoding: .utf8) else {
                return Result(state: .actionNeeded, message: "Prepare this phone's stable capture tunnel profile, then import it in WireGuard.", code: "iphone_profile_missing")
            }
            let lines = text.split(whereSeparator: \.isNewline).map(String.init)
            let privateKeys = lines.filter { $0.hasPrefix("PrivateKey = ") }
            let publicKeys = lines.filter { $0.hasPrefix("PublicKey = ") }
            let endpoints = lines.filter { $0.hasPrefix("Endpoint = ") }
            guard privateKeys.count == 1, publicKeys.count == 1, endpoints.count == 1,
                  let privateKey = Data(base64Encoded: String(privateKeys[0].dropFirst("PrivateKey = ".count))), privateKey.count == 32,
                  let client = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: privateKey),
                  let key = Data(base64Encoded: String(publicKeys[0].dropFirst("PublicKey = ".count))), key.count == 32,
                  endpoints[0].hasSuffix(":\(IPhoneCaptureSetup.listenPort)") else {
                return Result(state: .needsEngineerHelp, message: "The saved tunnel profile metadata is inconsistent. Ask an engineer to inspect it; no keys or profile files were changed.", code: "iphone_profile_invalid")
            }
            let host = String(endpoints[0].dropFirst("Endpoint = ".count).dropLast(":\(IPhoneCaptureSetup.listenPort)".count))
            let endpoint = try IPhoneCaptureSetup.validatedEndpointHost(host)
            // Bind cached evidence to both public peers and the endpoint. Never export or
            // directly fingerprint private bytes; deriving the client public identity also
            // validates the saved key without changing or regenerating the profile.
            var identity = Data("mobile-capture-profile-v2\0".utf8)
            identity.append(client.publicKey.rawRepresentation)
            identity.append(key)
            identity.append(Data("\0\(endpoint.lowercased()):\(IPhoneCaptureSetup.listenPort)".utf8))
            return Result(state: .readyToTry, message: "A private saved profile exists for this phone and Mac endpoint. Its presence does not establish phone import, activation or network reachability.", code: "iphone_profile_present", fingerprint: Self.digest(identity), endpoint: endpoint)
        } catch {
            return Result(state: .needsEngineerHelp, message: "The existing private profile could not be inspected safely. Ask an engineer to review its permissions or format; nothing was repaired or regenerated.", code: "iphone_profile_unsafe")
        }
    }

    func engineVersion() -> String? {
        guard let applicationBundle, let data = try? read(applicationBundle.appendingPathComponent("Contents/Resources/CaptureDependencies/dependencies.json"), maximum: 4 * 1024 * 1024, privateFile: false),
              let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = value["mitmproxy_version"] as? String, version.utf8.count <= 80 else { return nil }
        return version
    }

    func storage(directory: URL, minimumBytes: Int64) -> Result {
        guard directory.isFileURL, directory.path.hasPrefix("/") else {
            return Result(state: .unavailable, message: "Choose a local folder for private capture evidence.", code: "storage_not_local")
        }
        let fileManager = FileManager.default
        var ancestor = directory.standardizedFileURL
        while !fileManager.fileExists(atPath: ancestor.path) {
            let parent = ancestor.deletingLastPathComponent()
            guard parent != ancestor else { break }
            ancestor = parent
        }
        var info = stat()
        guard lstat(ancestor.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              fileManager.isWritableFile(atPath: ancestor.path) else {
            return Result(state: .unavailable, message: "The chosen evidence folder or its parent is unavailable or not writable. Choose another local folder.", code: "storage_unwritable")
        }
        if ancestor == directory.standardizedFileURL, info.st_uid != geteuid() || info.st_mode & 0o077 != 0 {
            return Result(state: .actionNeeded, message: "Choose a private user-owned capture folder. Inspection has not changed this folder's permissions.", code: "storage_not_private")
        }
        let available = availableDiskBytes.map { $0(ancestor) } ?? (try? ancestor.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage)
        if let available, available < minimumBytes {
            return Result(state: .actionNeeded, message: "Free more local disk space or choose another folder before capture. Network bodies and save staging can need space beyond log limits.", code: "storage_low_space")
        }
        return Result(state: .readyToTry, message: "Local storage is available for an initial capture. Missing session folders will be created privately by the capture host; full network bodies can grow beyond the log budget.", code: available == nil ? "storage_available_capacity_unknown" : "storage_available")
    }

    func routingOwner() -> Result {
        do {
            guard try privateDirectoryExists(routingLockDirectory) else {
                return Result(state: .readyToTry, message: "No capture connection owner is recorded. The host checks the shared lease again when starting.", code: "routing_owner_absent")
            }
            let file = routingLockDirectory.appendingPathComponent("owner.lock")
            let fd = Darwin.open(file.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
            if fd < 0, errno == ENOENT {
                return Result(state: .readyToTry, message: "No capture connection owner is recorded. The host checks the shared lease again when starting.", code: "routing_owner_absent")
            }
            guard fd >= 0 else { throw AppError("Ownership cannot be inspected") }
            defer { Darwin.close(fd) }
            var info = stat()
            guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == geteuid(), info.st_nlink == 1,
                  info.st_mode & 0o022 == 0, info.st_size >= 0, info.st_size <= 4_096 else { throw AppError("Unsafe ownership record") }
            // A nonblocking shared lock observes an existing exclusive owner without replacing
            // its inode or writing its path. Closing fd releases the brief read lock.
            guard flock(fd, LOCK_SH | LOCK_NB) == 0 else {
                return Result(state: .actionNeeded, message: "A capture currently owns the connection. Stop/save it or finish its recovery before another check.", code: "routing_owned")
            }
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
            let prior = String(decoding: try handle.read(upToCount: 4_096) ?? Data(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if !prior.isEmpty {
                guard prior.hasPrefix("/"), !prior.contains("\0") else { throw AppError("Invalid ownership record") }
                struct Prior: Decodable { let phase: String; let routing_restored: Bool? }
                if let data = try read(URL(fileURLWithPath: prior).appendingPathComponent("session.json"), maximum: 4 * 1024 * 1024, privateFile: false) {
                    let state = try JSONDecoder().decode(Prior.self, from: data)
                    if ["preparing", "recording", "stopping"].contains(state.phase) || state.routing_restored == false {
                        return Result(state: .actionNeeded, message: "A previous capture still needs connection recovery. Open that session and use Restore Connection & Save.", code: "routing_recovery_needed")
                    }
                }
            }
            return Result(state: .readyToTry, message: "No unresolved connection owner was found. The host checks the same shared lease again when starting.", code: "routing_owner_clear")
        } catch {
            return Result(state: .needsEngineerHelp, message: "The existing connection ownership record cannot be inspected safely. It was not replaced, repaired or cleared.", code: "routing_owner_unverified")
        }
    }

    private func privateDirectoryExists(_ url: URL) throws -> Bool {
        var info = stat()
        if lstat(url.path, &info) != 0, errno == ENOENT { return false }
        guard info.st_mode & S_IFMT == S_IFDIR, info.st_uid == geteuid(), info.st_mode & 0o077 == 0 else { throw AppError("Unsafe private directory") }
        return true
    }

    private func privateRegularFileExists(_ url: URL) throws -> Bool {
        var info = stat()
        if lstat(url.path, &info) != 0, errno == ENOENT { return false }
        guard info.st_mode & S_IFMT == S_IFREG, info.st_uid == geteuid(), info.st_mode & 0o077 == 0,
              info.st_nlink == 1, info.st_size >= 0, info.st_size <= 65_536 else { throw AppError("Unsafe private file") }
        return true
    }

    private func read(_ url: URL, maximum: Int, privateFile: Bool) throws -> Data? {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if descriptor < 0, errno == ENOENT { return nil }
        guard descriptor >= 0 else { throw AppError("Unreadable setup metadata") }
        defer { Darwin.close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == geteuid(), info.st_nlink == 1, info.st_size >= 0, info.st_size <= maximum,
              !privateFile || info.st_mode & 0o077 == 0 else { throw AppError("Unsafe setup metadata") }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        let data = try handle.read(upToCount: maximum + 1) ?? Data()
        guard data.count <= maximum else { throw AppError("Setup metadata exceeds limit") }
        return data
    }

    private static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}
