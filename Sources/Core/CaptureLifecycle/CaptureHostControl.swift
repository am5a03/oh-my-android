import CryptoKit
import Darwin
import Foundation

enum CaptureHostSocket {
    static func address(_ path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard path.utf8.count < capacity else { throw AppError("The private capture socket path is too long.") }
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: capacity) { buffer in
                _ = path.withCString { strlcpy(buffer, $0, capacity) }
            }
        }
        return address
    }

    static func send(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.send(descriptor, buffer.baseAddress!.advanced(by: offset), buffer.count - offset, 0)
                guard count > 0 else { throw AppError("The capture control connection closed.") }
                offset += count
            }
        }
    }

    static func receive(_ descriptor: Int32) throws -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while data.count < 8192 {
            let count = recv(descriptor, &buffer, min(buffer.count, 8192 - data.count), 0)
            if count <= 0 { break }
            data.append(buffer, count: count)
            if data.contains(10) { return data.prefix { $0 != 10 } }
        }
        throw AppError("Capture control returned an incomplete or oversized message.")
    }

    static func timeout(_ descriptor: Int32) {
        var time = timeval(tv_sec: 2, tv_usec: 0)
        _ = setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &time, socklen_t(MemoryLayout<timeval>.size))
        _ = setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &time, socklen_t(MemoryLayout<timeval>.size))
        var noSignal: Int32 = 1
        _ = setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
    }

    static func request(directory: URL, action: String) -> Bool {
        do {
            let control = try CaptureLifecycleFiles.read(CaptureHostControl.self, at: directory.appendingPathComponent("runtime/control.json"))
            var info = stat()
            guard lstat(control.socket, &info) == 0, info.st_mode & S_IFMT == S_IFSOCK,
                  info.st_uid == geteuid(), info.st_mode & 0o077 == 0 else { return false }
            let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
            guard descriptor >= 0 else { return false }
            defer { close(descriptor) }
            timeout(descriptor)
            var address = try address(control.socket)
            let connected = withUnsafePointer(to: &address) { pointer in pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            } }
            guard connected == 0 else { return false }
            var message = try JSONEncoder().encode(["action": action, "token": control.token]); message.append(10)
            try send(message, to: descriptor)
            let reply = try JSONDecoder().decode([String: CaptureStateValue].self, from: receive(descriptor))
            return reply["ok"] == .bool(true)
        } catch { return false }
    }

    static func token() -> String {
        SymmetricKey(size: .bits256).withUnsafeBytes { bytes in
            bytes.map { String(format: "%02x", $0) }.joined()
        }
    }
}

final class CaptureHostControlServer {
    private let descriptor: Int32
    private let control: CaptureHostControl

    init(control: CaptureHostControl) throws {
        self.control = control
        descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw AppError("Cannot open the private capture control socket.") }
        var address = try CaptureHostSocket.address(control.socket)
        let bound = withUnsafePointer(to: &address) { pointer in pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        } }
        guard bound == 0, chmod(control.socket, 0o600) == 0, listen(descriptor, 4) == 0 else {
            close(descriptor)
            throw AppError("Cannot bind the private capture control socket.")
        }
    }

    deinit { close(descriptor); _ = unlink(control.socket) }

    /// At most one bounded control message is handled per supervisor iteration.
    func takeStopRequest() -> Bool {
        var watched = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
        guard poll(&watched, 1, 0) > 0 else { return false }
        let client = accept(descriptor, nil, nil)
        guard client >= 0 else { return false }
        defer { close(client) }
        CaptureHostSocket.timeout(client)
        do {
            let message = try JSONDecoder().decode([String: String].self, from: CaptureHostSocket.receive(client))
            let supplied = Array((message["token"] ?? "").utf8), expected = Array(control.token.utf8)
            var difference = supplied.count == expected.count ? 0 : 1
            for (left, right) in zip(supplied, expected) { difference |= Int(left ^ right) }
            guard difference == 0, ["stop", "ping"].contains(message["action"] ?? "") else {
                try CaptureHostSocket.send(Data("{\"error\":\"Unauthorized session control\"}\n".utf8), to: client)
                return false
            }
            try CaptureHostSocket.send(Data("{\"ok\":true}\n".utf8), to: client)
            return message["action"] == "stop"
        } catch { return false }
    }
}
