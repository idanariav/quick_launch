import Foundation
import os

/// A request from outside the app (decision 0016). Over the control socket it's one
/// line of JSON, e.g. `{"type":"run","id":"system/caffeinate","args":{"duration":"2h"},"wait":true}`.
public struct ExternalRequest: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {
        /// Run the command `id`.
        case run
        /// List the commands that can run.
        case list
    }

    public var type: Kind
    /// A command id like `apps/com.apple.Safari`, for `run`.
    public var id: String?
    /// Parameter values as typed, by parameter id.
    public var args: [String: String]?
    /// Reply when the run ends, with its outcome, instead of once it starts.
    public var wait: Bool?

    public init(type: Kind, id: String? = nil, args: [String: String]? = nil, wait: Bool? = nil) {
        self.type = type
        self.id = id
        self.args = args
        self.wait = wait
    }

    /// `quicklaunch://run/<namespace>/<name>?<parameter>=<value>&…`
    public init(url: URL) throws(ActionFailure) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme == ExternalControl.urlScheme, components.host == Kind.run.rawValue else {
            throw ActionFailure("expected a link like quicklaunch://run/apps/com.apple.Safari")
        }
        var args: [String: String] = [:]
        for item in components.queryItems ?? [] {
            args[item.name] = item.value ?? ""
        }
        self.init(type: .run, id: String(components.path.drop { $0 == "/" }), args: args.isEmpty ? nil : args)
    }
}

/// The reply to an `ExternalRequest`.
public struct ExternalResponse: Codable, Sendable, Equatable {
    public var ok: Bool
    /// What a finished run reported, e.g. "Copied to clipboard".
    public var message: String?
    public var error: String?
    /// For `list`.
    public var commands: [ExternalCommand]?

    public init(ok: Bool, message: String? = nil, error: String? = nil, commands: [ExternalCommand]? = nil) {
        self.ok = ok
        self.message = message
        self.error = error
        self.commands = commands
    }

    public static func failure(_ error: String) -> ExternalResponse {
        ExternalResponse(ok: false, error: error)
    }
}

/// A command as `list` describes it.
public struct ExternalCommand: Codable, Sendable, Equatable {
    public struct Parameter: Codable, Sendable, Equatable {
        public var id: String
        public var title: String
        /// `text`, `integer`, `boolean`, `duration` or `choice`.
        public var kind: String
        public var options: [String]?
        public var defaultValue: String?
        public var optional: Bool

        enum CodingKeys: String, CodingKey {
            case id, title, kind, options, optional
            case defaultValue = "default"
        }
    }

    public var id: String
    public var title: String
    public var subtitle: String?
    public var parameters: [Parameter]
    /// Whether links may run it (`commands.<id>.external`).
    public var external: Bool
}

/// Runs commands for requests from outside the app: the control socket, which the
/// `quicklaunch` CLI and the Stream Deck plugin use, and `quicklaunch://` links
/// (decision 0016). Only the socket's own user can reach it, so it may run any
/// command; any app or web page can open a link, so links run only commands marked
/// `external: true`.
public final class ExternalControl: Sendable {
    public enum Origin: String, Sendable {
        case socket
        case url
    }

    public static let urlScheme = "quicklaunch"

    /// `~/Library/Application Support/QuickLaunch/control.sock`, shared with the CLI.
    public static let socketURL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appending(path: "QuickLaunch/control.sock")

    private let catalog: CommandCatalog
    private let runner: any ActionRunning
    private let frontmost: any FrontmostAppProviding
    private let log = Log.logger("external")

    public init(catalog: CommandCatalog, runner: any ActionRunning, frontmost: any FrontmostAppProviding) {
        self.catalog = catalog
        self.runner = runner
        self.frontmost = frontmost
    }

    public func handle(_ request: ExternalRequest, from origin: Origin) async -> ExternalResponse {
        switch request.type {
        case .list:
            guard origin == .socket else { return .failure("links can only run commands") }
            return await list()
        case .run:
            let response = await run(request, from: origin)
            if let error = response.error {
                log.error("Refused a request from the \(origin.rawValue, privacy: .public): \(error, privacy: .public)")
            }
            return response
        }
    }

    /// A `quicklaunch://run/…` link.
    public func handle(url: URL) async -> ExternalResponse {
        do {
            return await handle(try ExternalRequest(url: url), from: .url)
        } catch {
            log.error("Refused a link: \(error.message, privacy: .public)")
            return .failure(error.message)
        }
    }

    /// One line of JSON in, one out (with its newline), for the socket.
    public func handle(json: Data) async -> Data {
        let response: ExternalResponse
        do {
            response = await handle(try JSONDecoder().decode(ExternalRequest.self, from: json), from: .socket)
        } catch {
            response = .failure("not a valid request: \(error.localizedDescription)")
        }
        return ((try? JSONEncoder().encode(response)) ?? Data()) + Data("\n".utf8)
    }

    private func run(_ request: ExternalRequest, from origin: Origin) async -> ExternalResponse {
        let id: CommandID
        do {
            id = try CommandID(configScalar: request.id ?? "")
        } catch {
            return .failure(error.message)
        }
        // Discovered commands (apps, snippets) may be newer than the last refresh.
        var found = await catalog.command(id)
        if found == nil {
            await catalog.refresh()
            found = await catalog.command(id)
        }
        guard let command = found else { return .failure("no such command '\(id)'") }
        let settings = catalog.settings
        if settings.isDisabled(id) { return .failure("\(command.title) is switched off") }
        if origin == .url, !settings.isExternal(id) {
            return .failure("\(command.title) can't be run from links; allow it in Settings or with commands.\(id).external: true")
        }
        // Caught here rather than in the run, so a request without `wait` hears about a typo too.
        let parameters = Set(command.parameters.map(\.id))
        if let unknown = request.args?.keys.sorted().first(where: { !parameters.contains($0) }) {
            let expected = parameters.isEmpty ? "it takes no arguments" : "expected one of: \(command.parameters.map(\.id).joined(separator: ", "))"
            return .failure("unknown argument '\(unknown)'; \(expected)")
        }

        let source = ConfigPath(file: origin == .url ? "the link" : "the request", components: [.key("args")])
        let run = RunRequest(
            target: .command(CommandReference(id: id, arguments: request.args.map { ArgumentTexts($0, source: source) })),
            trigger: .external, frontmostApp: frontmost.current, key: "external:\(id)"
        )
        log.info("Running \(id, privacy: .public) for the \(origin.rawValue, privacy: .public)")
        guard request.wait == true else {
            Task { [runner] in await runner.run(run) }
            return ExternalResponse(ok: true)
        }
        return switch await runner.run(run) {
        case .succeeded(let message): ExternalResponse(ok: true, message: message)
        case .failed(let message): .failure(message)
        case .cancelled: .failure("cancelled")
        case .running: .failure("still running")
        }
    }

    private func list() async -> ExternalResponse {
        await catalog.refresh()
        let settings = catalog.settings
        let commands = await catalog.allCommands().map { id, command in
            ExternalCommand(
                id: id.description, title: command.title, subtitle: command.subtitle,
                parameters: command.parameters.map(Self.describe), external: settings.isExternal(id)
            )
        }
        return ExternalResponse(ok: true, commands: commands)
    }

    private static func describe(_ parameter: CommandParameter) -> ExternalCommand.Parameter {
        var options: [String]?
        let kind: String
        switch parameter.kind {
        case .text: kind = "text"
        case .integer: kind = "integer"
        case .boolean: kind = "boolean"
        case .duration: kind = "duration"
        case .choice(let values):
            kind = "choice"
            options = values
        }
        return ExternalCommand.Parameter(
            id: parameter.id, title: parameter.title, kind: kind, options: options,
            defaultValue: parameter.defaultValue, optional: parameter.isOptional
        )
    }
}
