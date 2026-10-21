import Darwin
import Foundation
import QLCore

/// A Unix domain socket that answers one line of JSON per connection with one line
/// back (decision 0016). The socket file is the user's alone (mode 0600), and each
/// connection's peer must be the same user.
public final class ControlSocketServer: Sendable {
    private let url: URL
    private let handle: @Sendable (Data) async -> Data
    private let log = Log.logger("external")
    /// Longest request accepted; requests are a command id and a few arguments.
    private static let maxRequest = 64 * 1024

    public init(url: URL = ExternalControl.socketURL, handle: @escaping @Sendable (Data) async -> Data) {
        self.url = url
        self.handle = handle
    }

    /// Binds the socket, replacing a stale one, and accepts connections on a thread of
    /// its own until the process exits.
    public func start() {
        do {
            let socket = try bind()
            let thread = Thread { [self] in acceptLoop(socket) }
            thread.name = "QuickLaunch control socket"
            thread.start()
            log.info("Control socket at \(self.url.path, privacy: .public)")
        } catch {
            log.error("Control socket unavailable: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func bind() throws -> Int32 {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        unlink(url.path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError.current }
        var address = try UnixSocketAddress(path: url.path)
        let bound = withUnsafePointer(to: &address.raw) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, chmod(url.path, 0o600) == 0, listen(fd, 16) == 0 else {
            let error = POSIXError.current
            close(fd)
            throw error
        }
        return fd
    }

    private func acceptLoop(_ socket: Int32) {
        while true {
            let connection = accept(socket, nil, nil)
            guard connection >= 0 else {
                if errno == EINTR { continue }
                log.error("Control socket stopped: \(POSIXError.current.localizedDescription, privacy: .public)")
                return
            }
            var uid: uid_t = 0
            var gid: gid_t = 0
            guard getpeereid(connection, &uid, &gid) == 0, uid == getuid() else {
                close(connection)
                continue
            }
            DispatchQueue.global().async { [self] in serve(connection) }
        }
    }

    private func serve(_ connection: Int32) {
        // A client that stops writing mid-request shouldn't hold the connection forever.
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(connection, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        // A client that disconnects before the reply must not kill the app with SIGPIPE.
        var one: Int32 = 1
        setsockopt(connection, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))

        var request = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while request.count < Self.maxRequest, !request.contains(UInt8(ascii: "\n")) {
            let count = read(connection, &buffer, buffer.count)
            guard count > 0 else { break }
            request.append(contentsOf: buffer[..<count])
        }
        let line = request.prefix { $0 != UInt8(ascii: "\n") }
        Task { [handle] in
            let reply = await handle(Data(line))
            reply.withUnsafeBytes { bytes in
                var offset = 0
                while offset < bytes.count {
                    let written = write(connection, bytes.baseAddress! + offset, bytes.count - offset)
                    guard written > 0 else { break }
                    offset += written
                }
            }
            close(connection)
        }
    }
}

/// A `sockaddr_un` for a path, which must fit its fixed-size buffer.
struct UnixSocketAddress {
    var raw = sockaddr_un()

    init(path: String) throws {
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: raw.sun_path) else { throw POSIXError(.ENAMETOOLONG) }
        raw.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &raw.sun_path) { buffer in
            buffer.copyBytes(from: bytes)
        }
    }
}

extension POSIXError {
    static var current: POSIXError { POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
}
