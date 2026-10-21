import Darwin
import Foundation
import Testing
@testable import QLPlatform

/// The control socket (decision 0016) with a real socket file and a stand-in handler.
struct ControlSocketServerTests {
    /// Short, since a socket path must fit in `sockaddr_un` (104 bytes); the temporary directory's doesn't.
    private let url = URL(filePath: "/tmp/ql-test-\(UUID().uuidString.prefix(8)).sock")

    @Test func answersEachRequestLineAndIsTheUsersAlone() async throws {
        defer { unlink(url.path) }
        let server = ControlSocketServer(url: url) { request in
            Data("got \(String(decoding: request, as: UTF8.self))\n".utf8)
        }
        server.start()

        #expect(try send("hello\nignored after the line", to: url) == "got hello\n")
        #expect(try send("again\n", to: url) == "got again\n")
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        #expect(permissions == 0o600)
    }

    @Test func aStaleSocketFileIsReplaced() throws {
        defer { unlink(url.path) }
        FileManager.default.createFile(atPath: url.path, contents: Data("stale".utf8))
        ControlSocketServer(url: url) { _ in Data("fresh\n".utf8) }.start()
        #expect(try send("x\n", to: url) == "fresh\n")
    }
}

private func send(_ text: String, to url: URL) throws -> String {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    defer { close(fd) }
    var address = try UnixSocketAddress(path: url.path)
    let connected = withUnsafePointer(to: &address.raw) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    guard connected == 0 else { throw POSIXError.current }
    _ = text.withCString { write(fd, $0, strlen($0)) }
    var reply = Data()
    var buffer = [UInt8](repeating: 0, count: 256)
    while true {
        let count = read(fd, &buffer, buffer.count)
        guard count > 0 else { break }
        reply.append(contentsOf: buffer[..<count])
    }
    return String(decoding: reply, as: UTF8.self)
}
