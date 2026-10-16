import CryptoKit
import Darwin
import Foundation

/// Paths point into private application support, never a capture session or its export.
nonisolated struct IPhoneTunnelConfiguration: Sendable, Equatable {
    let serverConfiguration: URL
    let clientProfile: URL
    let endpointHost: String
    let port: UInt16
}

nonisolated struct IPhoneCaptureLANAddress: Sendable, Equatable {
    let interfaceName: String
    let address: String
}

/// Creates the key-file format consumed by mitmproxy 12.2.3's WireGuard mode.
/// Both files contain private keys and must stay outside evidence and diagnostic logs.
nonisolated enum IPhoneCaptureSetup {
    static let listenPort: UInt16 = 51820
    static var defaultRootDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/MobileCapture/IPhoneTunnels", isDirectory: true)
    }

    static func prepare(deviceID: String, endpointHost: String, rootDirectory: URL? = nil, evidenceRoot: URL? = nil) throws -> IPhoneTunnelConfiguration {
        let endpoint = try validatedEndpointHost(endpointHost)
        if let evidenceRoot {
            let storage = resolvingExistingAncestor(rootDirectory ?? defaultRootDirectory)
            let evidence = resolvingExistingAncestor(evidenceRoot)
            guard storage != evidence, !storage.path.hasPrefix(evidence.path + "/") else {
                throw SetupError.evidenceStorageOverlap
            }
        }
        let directory = try deviceDirectory(deviceID: deviceID, rootDirectory: rootDirectory, create: true)
        let server = directory.appendingPathComponent("server.json")
        let profile = directory.appendingPathComponent("MobileCapture.conf")
        let keys: Keys
        if let existing = try readPrivateFile(server) {
            keys = try decodeKeys(existing)
        } else {
            let generated = Keys(serverKey: Curve25519.KeyAgreement.PrivateKey().rawRepresentation.base64EncodedString(),
                                 clientKey: Curve25519.KeyAgreement.PrivateKey().rawRepresentation.base64EncodedString())
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            // An exclusive link publishes a complete file without replacing another caller's keys.
            if try atomicWrite(encoder.encode(generated), to: server, replace: false) {
                keys = generated
            } else {
                guard let existing = try readPrivateFile(server) else { throw SetupError.unreadableConfiguration }
                keys = try decodeKeys(existing)
            }
        }
        // Validate an existing entry without following symlinks before replacing it.
        _ = try readPrivateFile(profile)
        _ = try atomicWrite(Data(try clientConfiguration(keys: keys, endpointHost: endpoint).utf8), to: profile, replace: true)
        return IPhoneTunnelConfiguration(serverConfiguration: server, clientProfile: profile, endpointHost: endpoint, port: listenPort)
    }

    /// Foundation leaves symlinks in place if the final path does not exist yet.
    private static func resolvingExistingAncestor(_ url: URL) -> URL {
        var ancestor = url.standardizedFileURL
        var missing: [String] = []
        while !FileManager.default.fileExists(atPath: ancestor.path) {
            let parent = ancestor.deletingLastPathComponent()
            guard parent != ancestor else { break }
            missing.append(ancestor.lastPathComponent)
            ancestor = parent
        }
        return missing.reversed().reduce(ancestor.resolvingSymlinksInPath().standardizedFileURL) { $0.appendingPathComponent($1) }
    }

    static func readExisting(deviceID: String, rootDirectory: URL? = nil) throws -> IPhoneTunnelConfiguration? {
        let directory = try deviceDirectory(deviceID: deviceID, rootDirectory: rootDirectory, create: false)
        let server = directory.appendingPathComponent("server.json")
        let profile = directory.appendingPathComponent("MobileCapture.conf")
        guard let serverData = try readPrivateFile(server, repairPermissions: false), let profileData = try readPrivateFile(profile, repairPermissions: false),
              let text = String(data: profileData, encoding: .utf8) else { return nil }
        let keys = try decodeKeys(serverData)
        let prefix = "Endpoint = "
        guard let endpointLine = text.split(separator: "\n").first(where: { $0.hasPrefix(prefix) }),
              endpointLine.hasSuffix(":\(listenPort)") else { throw SetupError.unreadableConfiguration }
        let host = String(endpointLine.dropFirst(prefix.count).dropLast(":\(listenPort)".count))
        let endpoint = try validatedEndpointHost(host)
        guard text == (try clientConfiguration(keys: keys, endpointHost: endpoint)) else { throw SetupError.unreadableConfiguration }
        return IPhoneTunnelConfiguration(serverConfiguration: server, clientProfile: profile, endpointHost: endpoint, port: listenPort)
    }

    /// Call only for a destination the user has approved, including replacing an existing file.
    /// An exported profile contains its client private key and is private from the first write.
    static func exportClientProfile(_ configuration: IPhoneTunnelConfiguration, to destination: URL) throws {
        guard destination.isFileURL,
              destination.standardizedFileURL.resolvingSymlinksInPath() != configuration.serverConfiguration.standardizedFileURL.resolvingSymlinksInPath() else {
            throw SetupError.invalidExportDestination
        }
        var info = stat()
        if lstat(destination.path, &info) == 0 {
            guard info.st_mode & S_IFMT == S_IFREG, info.st_uid == geteuid() else { throw SetupError.invalidExportDestination }
        } else if errno != ENOENT { throw SetupError.invalidExportDestination }
        guard let data = try readPrivateFile(configuration.clientProfile) else { throw SetupError.unreadableConfiguration }
        _ = try atomicWrite(data, to: destination, replace: true)
    }

    /// Active LAN interfaces only; excludes loopback, VPN, peer-to-peer and link-local addresses.
    static func localIPv4Addresses() -> [IPhoneCaptureLANAddress] {
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0, let first else { return [] }
        defer { freeifaddrs(first) }
        var addresses: [IPhoneCaptureLANAddress] = []
        var current: UnsafeMutablePointer<ifaddrs>? = first
        while let item = current {
            defer { current = item.pointee.ifa_next }
            let interface = item.pointee
            guard interface.ifa_flags & UInt32(IFF_UP) != 0,
                  interface.ifa_flags & UInt32(IFF_RUNNING) != 0,
                  interface.ifa_flags & UInt32(IFF_LOOPBACK | IFF_POINTOPOINT) == 0,
                  let address = interface.ifa_addr, address.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: interface.ifa_name)
            guard !["utun", "awdl", "llw", "lo"].contains(where: { name.hasPrefix($0) }) else { continue }
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let host = buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
            guard (try? validatedEndpointHost(host)) != nil, !host.hasPrefix("169.254.") else { continue }
            let entry = IPhoneCaptureLANAddress(interfaceName: name, address: host)
            if !addresses.contains(entry) { addresses.append(entry) }
        }
        return addresses.sorted {
            let left = $0.interfaceName.hasPrefix("en"), right = $1.interfaceName.hasPrefix("en")
            if left != right { return left }
            if $0.interfaceName != $1.interfaceName { return $0.interfaceName < $1.interfaceName }
            return $0.address < $1.address
        }
    }

    static func defaultEndpointHost() -> String? { localIPv4Addresses().first?.address }

    /// A hostname or IPv4 address, without a scheme, port, whitespace or configuration syntax.
    static func validatedEndpointHost(_ value: String) throws -> String {
        let host = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty, host.utf8.count <= 253,
              host.utf8.allSatisfy({ ($0 >= 48 && $0 <= 57) || ($0 >= 65 && $0 <= 90) || ($0 >= 97 && $0 <= 122) || $0 == 45 || $0 == 46 }) else {
            throw SetupError.invalidEndpoint
        }
        if host.utf8.allSatisfy({ ($0 >= 48 && $0 <= 57) || $0 == 46 }) {
            var address = in_addr()
            guard host.withCString({ inet_pton(AF_INET, $0, &address) }) == 1 else { throw SetupError.invalidEndpoint }
            let octets = host.split(separator: ".").compactMap { UInt8($0) }
            guard octets.count == 4, octets[0] != 0, octets[0] != 127, octets[0] < 224,
                  host != "255.255.255.255" else { throw SetupError.invalidEndpoint }
        } else {
            let labels = host.split(separator: ".", omittingEmptySubsequences: false)
            guard host.lowercased() != "localhost", labels.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 63 && $0.first != "-" && $0.last != "-" }) else {
                throw SetupError.invalidEndpoint
            }
        }
        return host
    }

    private struct Keys: Codable {
        let serverKey: String
        let clientKey: String
        enum CodingKeys: String, CodingKey { case serverKey = "server_key", clientKey = "client_key" }
    }

    private static func decodeKeys(_ data: Data) throws -> Keys {
        guard let keys = try? JSONDecoder().decode(Keys.self, from: data),
              let server = Data(base64Encoded: keys.serverKey), server.count == 32,
              let client = Data(base64Encoded: keys.clientKey), client.count == 32,
              (try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: server)) != nil,
              (try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: client)) != nil else {
            throw SetupError.unreadableConfiguration
        }
        return keys
    }

    private static func clientConfiguration(keys: Keys, endpointHost: String) throws -> String {
        guard let raw = Data(base64Encoded: keys.serverKey),
              let key = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: raw) else { throw SetupError.unreadableConfiguration }
        // Match the pinned engine's client profile. Its IPv6 proxy support remains incomplete.
        return """
        [Interface]
        PrivateKey = \(keys.clientKey)
        Address = 10.0.0.1/32
        DNS = 10.0.0.53

        [Peer]
        PublicKey = \(key.publicKey.rawRepresentation.base64EncodedString())
        AllowedIPs = 0.0.0.0/0
        Endpoint = \(endpointHost):\(listenPort)

        """
    }

    private static func deviceDirectory(deviceID: String, rootDirectory: URL?, create: Bool) throws -> URL {
        guard !deviceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw SetupError.invalidDevice }
        let root = rootDirectory ?? defaultRootDirectory
        guard root.isFileURL else { throw SetupError.unreadableConfiguration }
        let digest = SHA256.hash(data: Data(deviceID.utf8)).map { String(format: "%02x", $0) }.joined()
        let directory = root.appendingPathComponent(digest, isDirectory: true)
        if create {
            try privateDirectory(root, create: true)
            try privateDirectory(directory, create: true)
        } else {
            try privateDirectory(root, create: false)
            try privateDirectory(directory, create: false)
        }
        return directory
    }

    private static func privateDirectory(_ url: URL, create: Bool) throws {
        if create { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
        let descriptor = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if descriptor < 0, errno == ENOENT, !create { return }
        guard descriptor >= 0 else { throw SetupError.unsafeStorage }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_uid == geteuid() else { throw SetupError.unsafeStorage }
        if create {
            guard fchmod(descriptor, 0o700) == 0 else { throw SetupError.unsafeStorage }
        } else {
            guard info.st_mode & 0o077 == 0 else { throw SetupError.unsafeStorage }
        }
    }

    private static func readPrivateFile(_ url: URL, repairPermissions: Bool = true) throws -> Data? {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        if descriptor < 0, errno == ENOENT { return nil }
        guard descriptor >= 0 else { throw SetupError.unsafeStorage }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == geteuid(),
              info.st_size >= 0, info.st_size <= 65_536 else { throw SetupError.unsafeStorage }
        if repairPermissions {
            guard fchmod(descriptor, 0o600) == 0 else { throw SetupError.unsafeStorage }
        } else {
            guard info.st_mode & 0o077 == 0 else { throw SetupError.unsafeStorage }
        }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 4_096)
        while true {
            let count = read(descriptor, &buffer, buffer.count)
            if count == 0 { return data }
            if count < 0, errno == EINTR { continue }
            guard count > 0, data.count + count <= 65_536 else { throw SetupError.unreadableConfiguration }
            data.append(contentsOf: buffer.prefix(count))
        }
    }

    /// The temporary entry is private from creation; rename/link publishes only a complete file.
    @discardableResult private static func atomicWrite(_ data: Data, to destination: URL, replace: Bool) throws -> Bool {
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".setup-\(UUID().uuidString)")
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw SetupError.unsafeStorage }
        defer { close(descriptor); unlink(temporary.path) }
        guard fchmod(descriptor, 0o600) == 0 else { throw SetupError.unsafeStorage }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw SetupError.unreadableConfiguration }
                offset += count
            }
        }
        guard fsync(descriptor) == 0 else { throw SetupError.unreadableConfiguration }
        if replace {
            guard rename(temporary.path, destination.path) == 0 else { throw SetupError.unreadableConfiguration }
        } else if link(temporary.path, destination.path) != 0 {
            if errno == EEXIST { return false }
            throw SetupError.unreadableConfiguration
        }
        return true
    }

    enum SetupError: LocalizedError {
        case invalidEndpoint, invalidDevice, unsafeStorage, unreadableConfiguration, invalidExportDestination, evidenceStorageOverlap
        var errorDescription: String? {
            switch self {
            case .invalidEndpoint: "Enter this Mac's LAN IPv4 address or hostname, without a URL scheme or port."
            case .invalidDevice: "Choose a connected iPhone before preparing its capture profile."
            case .unsafeStorage: "The iPhone capture setup folder or file is not safe to use. Choose a private folder owned by your account."
            case .unreadableConfiguration: "The private iPhone capture configuration could not be read or saved. Prepare the setup again."
            case .invalidExportDestination: "Choose a regular file location for the WireGuard client profile, outside the private server configuration."
            case .evidenceStorageOverlap: "Private iPhone tunnel keys must be stored outside the capture output directory."
            }
        }
    }
}
