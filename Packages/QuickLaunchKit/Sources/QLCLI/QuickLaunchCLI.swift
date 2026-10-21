import ArgumentParser
import Darwin
import Foundation
import QLCore

/// `quicklaunch`: runs and lists QuickLaunch commands through the running app's
/// control socket (decision 0016).
@main
struct QuickLaunchCLI: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "quicklaunch",
        abstract: "Run QuickLaunch commands from the command line.",
        discussion: "Talks to the running app. Command ids are shown by `quicklaunch list`.",
        subcommands: [Run.self, List.self]
    )
}

struct Run: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Run a command, e.g. `quicklaunch run system/caffeinate --arg duration=2h`.")

    @Argument(help: "The command id, like apps/com.apple.Safari.")
    var id: String

    @Option(name: .customLong("arg"), help: ArgumentHelp("A parameter value; repeat for more.", valueName: "name=value"))
    var arguments: [String] = []

    @Flag(help: "Wait for the run to finish, print its message, and exit with its outcome.")
    var wait = false

    func run() throws {
        var args: [String: String] = [:]
        for argument in arguments {
            guard let equals = argument.firstIndex(of: "=") else {
                throw ValidationError("--arg takes name=value, found '\(argument)'")
            }
            args[String(argument[..<equals])] = String(argument[argument.index(after: equals)...])
        }
        let response = try send(ExternalRequest(type: .run, id: id, args: args.isEmpty ? nil : args, wait: wait))
        if let message = response.message { print(message) }
    }
}

struct List: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "List the commands that can run.")

    @Flag(help: "Print JSON, with each command's parameters.")
    var json = false

    func run() throws {
        let commands = try send(ExternalRequest(type: .list)).commands ?? []
        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            print(String(decoding: try encoder.encode(commands), as: UTF8.self))
            return
        }
        let width = commands.map(\.id.count).max() ?? 0
        for command in commands {
            print(command.id.padding(toLength: width, withPad: " ", startingAt: 0) + "  " + command.title)
        }
    }
}

/// Sends one request and returns the reply. A refused request prints its error and
/// exits with 1; not reaching the app exits with 2.
private func send(_ request: ExternalRequest) throws -> ExternalResponse {
    let reply: Data
    do {
        reply = try exchange(try JSONEncoder().encode(request) + Data("\n".utf8))
    } catch {
        FileHandle.standardError.write(Data("quicklaunch: QuickLaunch isn't running, or its control socket is unavailable (\(error.localizedDescription))\n".utf8))
        throw ExitCode(2)
    }
    let response = try JSONDecoder().decode(ExternalResponse.self, from: reply)
    if !response.ok {
        FileHandle.standardError.write(Data("quicklaunch: \(response.error ?? "failed")\n".utf8))
        throw ExitCode.failure
    }
    return response
}

/// Writes `request` to the control socket and reads the reply until the app closes it.
private func exchange(_ request: Data) throws -> Data {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw POSIXError(.EIO) }
    defer { close(fd) }
    var one: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))

    var address = sockaddr_un()
    let path = Array(ExternalControl.socketURL.path.utf8)
    guard path.count < MemoryLayout.size(ofValue: address.sun_path) else { throw POSIXError(.ENAMETOOLONG) }
    address.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: path) }
    let connected = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    guard connected == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }

    try request.withUnsafeBytes { bytes in
        var offset = 0
        while offset < bytes.count {
            let written = write(fd, bytes.baseAddress! + offset, bytes.count - offset)
            guard written > 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            offset += written
        }
    }
    var reply = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while true {
        let count = read(fd, &buffer, buffer.count)
        guard count > 0 else { break }
        reply.append(contentsOf: buffer[..<count])
    }
    return reply
}
