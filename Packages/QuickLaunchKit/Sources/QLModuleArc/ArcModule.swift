import Foundation
import QLCore

/// Arc, the browser (decision 0024), through its AppleScript dictionary (as JavaScript
/// for Automation) and its sidebar file:
///
/// - `arc/search`: opens the selection (or typed text) in a new tab, as a URL or a web search;
/// - `arc/copy_link`: copies the current tab as a Markdown link;
/// - `arc/tabs`: open tabs to switch to (⏎) or close (⌘⏎);
/// - `arc/space/<name>`: focuses a space, one command per space.
///
/// ```yaml
/// arc:
///   search_engine: google   # google | duckduckgo | kagi | perplexity | bing
/// ```
public struct ArcModule: Module {
    public let id = "arc"
    public let plugin: PluginInfo? = PluginInfo(title: "Arc", summary: "Open and search tabs, copy links and switch spaces in the Arc browser")
    static let app = CommandApp(bundleID: "company.thebrowser.Browser", name: "Arc")

    private let processes: any ProcessRunning
    private let clipboard: any ClipboardService
    private let sidebar: any ArcSidebarReading

    public init(processes: any ProcessRunning, clipboard: any ClipboardService) {
        self.init(processes: processes, clipboard: clipboard, sidebar: ArcSidebarFile())
    }

    init(processes: any ProcessRunning, clipboard: any ClipboardService, sidebar: any ArcSidebarReading) {
        self.processes = processes
        self.clipboard = clipboard
        self.sidebar = sidebar
    }

    public func configure(_ section: ConfigReader, into contributions: inout Contributions) {
        let engine = section.value("search_engine", as: SearchEngine.self) ?? .google
        let arc = ArcScripting(processes: processes)
        contributions.command(Command(
            name: "search", title: "New Arc Tab", subtitle: "Open a URL or search the web, from the selection or typed text",
            icon: .symbol("plus.magnifyingglass"), io: ActionIO(input: .selection, output: OutputTarget.none),
            parameters: [CommandParameter(id: "engine", title: "Search with", kind: .choice(SearchEngine.allCases.map(\.rawValue)), defaultValue: engine.rawValue)],
            app: Self.app, action: OpenInArcAction(processes: processes)
        ))
        contributions.command(Command(
            name: "copy_link", title: "Copy Arc Tab as Markdown Link", subtitle: "[title](url) of the current tab",
            icon: .symbol("link"), app: Self.app, action: CopyArcLinkAction(arc: arc, clipboard: clipboard)
        ))
        contributions.command(Command(
            name: "tabs", title: "Arc Tabs", subtitle: "Switch to an open tab, or close it",
            icon: .symbol("square.on.square"), showsList: true, app: Self.app, action: ChooseArcTabAction(arc: arc)
        ))
        contributions.commandProvider(ArcSpaceCommands(sidebar: sidebar, arc: arc))
    }
}

enum SearchEngine: String, ConfigEnum, CaseIterable {
    case google, duckduckgo, kagi, perplexity, bing

    func url(for query: String) -> URL? {
        var components: URLComponents?
        switch self {
        case .google: components = URLComponents(string: "https://www.google.com/search")
        case .duckduckgo: components = URLComponents(string: "https://duckduckgo.com/")
        case .kagi: components = URLComponents(string: "https://kagi.com/search")
        case .perplexity: components = URLComponents(string: "https://www.perplexity.ai/search")
        case .bing: components = URLComponents(string: "https://www.bing.com/search")
        }
        components?.queryItems = [URLQueryItem(name: "q", value: query)]
        return components?.url
    }
}

// MARK: - Spaces

/// One command per space in Arc's sidebar file, so they're listed even while Arc is closed.
struct ArcSpaceCommands: CommandProvider {
    let sidebar: any ArcSidebarReading
    let arc: ArcScripting

    func commands() async -> [Command] {
        sidebar.spaceTitles().map { title in
            Command(
                name: "space/\(Self.slug(title))", title: "Arc Space: \(title)", subtitle: "Focus this space",
                icon: .symbol("rectangle.stack"), app: ArcModule.app, action: FocusArcSpaceAction(arc: arc, space: title)
            )
        }
    }

    /// A readable, stable command name: lowercase, with runs of anything but letters and digits as `_`.
    static func slug(_ name: String) -> String {
        name.lowercased().split { !$0.isLetter && !$0.isNumber }.joined(separator: "_")
    }
}

/// Space titles from Arc's sidebar file.
protocol ArcSidebarReading: Sendable {
    func spaceTitles() -> [String]
}

/// `~/Library/Application Support/Arc/StorableSidebar.json`. Its `spaces` list alternates
/// ids and space objects; only the objects' titles are read.
struct ArcSidebarFile: ArcSidebarReading {
    var url = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support/Arc/StorableSidebar.json")

    func spaceTitles() -> [String] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return Self.spaceTitles(in: data)
    }

    static func spaceTitles(in data: Data) -> [String] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let containers = (root["sidebar"] as? [String: Any])?["containers"] as? [[String: Any]] else { return [] }
        return containers.flatMap { ($0["spaces"] as? [Any]) ?? [] }
            .compactMap { ($0 as? [String: Any])?["title"] as? String }
            .filter { !$0.isEmpty }
    }
}

// MARK: - Scripting

/// Runs JavaScript for Automation against Arc. Values go into scripts as JSON literals,
/// so no text from a page or the user can change a script.
struct ArcScripting: Sendable {
    let processes: any ProcessRunning

    struct Tab: Decodable, Equatable {
        let window: String
        let id: String
        let title: String
        let url: String
        /// `topApp`, `pinned` or `unpinned`.
        let location: String
    }

    struct Link: Decodable, Equatable {
        let title: String
        let url: String
    }

    func tabs() async throws -> [Tab] {
        try JSONDecoder().decode([Tab].self, from: Data(try await run("""
            const out = [];
            for (const w of arc.windows()) {
              const window = String(w.id()), ids = w.tabs.id(), titles = w.tabs.title(), urls = w.tabs.url(), locations = w.tabs.location();
              ids.forEach((id, i) => out.push({ window, id: String(id), title: titles[i] || "", url: urls[i] || "", location: locations[i] || "" }));
            }
            return JSON.stringify(out);
            """).utf8))
    }

    func activeTab() async throws -> Link {
        try JSONDecoder().decode(Link.self, from: Data(try await run("""
            if (arc.windows.length === 0) throw new Error("Arc has no open window");
            const tab = arc.windows[0].activeTab;
            return JSON.stringify({ title: tab.title() || "", url: tab.url() || "" });
            """).utf8))
    }

    func select(_ tab: Tab) async throws {
        _ = try await run("""
            const window = arc.windows().find(w => String(w.id()) === \(Self.literal(tab.window)));
            if (!window) throw new Error("that window is closed");
            window.tabs.byId(\(Self.literal(tab.id))).select();
            arc.activate();
            return "";
            """)
    }

    func close(_ tab: Tab) async throws {
        _ = try await run("""
            const window = arc.windows().find(w => String(w.id()) === \(Self.literal(tab.window)));
            if (window) window.tabs.byId(\(Self.literal(tab.id))).close();
            return "";
            """)
    }

    func focusSpace(_ title: String) async throws {
        _ = try await run("""
            arc.activate();
            if (arc.windows.length === 0) throw new Error("Arc has no open window");
            const spaces = arc.windows[0].spaces.whose({ title: \(Self.literal(title)) });
            if (spaces.length === 0) throw new Error("there's no space named " + \(Self.literal(title)));
            spaces[0].focus();
            return "";
            """)
    }

    /// Runs `body` as the body of `run()`, with `arc` bound to the app; returns what it returns.
    private func run(_ body: String) async throws -> String {
        let script = "function run() {\nconst arc = Application(\"Arc\");\n\(body)\n}"
        let collected = Collected()
        let result = try await processes.run(
            ProcessRequest(executable: "/usr/bin/osascript", arguments: ["-l", "JavaScript", "-e", script])
        ) { await collected.append($0) }
        guard result.exitCode == 0 else { throw ActionFailure(Self.message(result.stderr)) }
        return await collected.text
    }

    /// osascript's `execution error: Error: <message> (-2700)` as just the message.
    static func message(_ stderr: String) -> String {
        var text = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = text.range(of: "Error: ", options: .backwards) { text = String(text[range.upperBound...]) }
        if let paren = text.range(of: " (-", options: .backwards) { text = String(text[..<paren.lowerBound]) }
        if text.contains("Not authorized") || text.contains("-1743") {
            return "QuickLaunch isn't allowed to control Arc; allow it in System Settings → Privacy & Security → Automation"
        }
        return text.isEmpty ? "Arc didn't respond" : text
    }

    /// `text` as a JavaScript string literal.
    static func literal(_ text: String) -> String {
        (try? String(decoding: JSONEncoder().encode(text), as: UTF8.self)) ?? "\"\""
    }

    private actor Collected {
        private var data = Data()
        func append(_ chunk: Data) { data.append(chunk) }
        var text: String { String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }
    }
}

// MARK: - Actions

struct OpenInArcAction: Action {
    let processes: any ProcessRunning

    func run(_ invocation: Invocation) async throws {
        let text = (invocation.input ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ActionFailure("type a URL or something to search for") }
        let engine = invocation.arguments.text("engine").flatMap(SearchEngine.init(rawValue:)) ?? .google
        guard let url = Self.address(text) ?? engine.url(for: text) else { throw ActionFailure("couldn't make a URL of that") }
        let result = try await processes.run(ProcessRequest(executable: "/usr/bin/open", arguments: ["-a", "Arc", url.absoluteString])) { _ in }
        guard result.exitCode == 0 else { throw ActionFailure("couldn't open Arc: \(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))") }
    }

    /// `text` as a web address, if it is one: with a scheme, or a single word with a dot
    /// like `example.com/path` (then https).
    static func address(_ text: String) -> URL? {
        guard !text.contains(where: \.isWhitespace) else { return nil }
        if let url = URL(string: text), let scheme = url.scheme, ["http", "https", "file"].contains(scheme.lowercased()) { return url }
        let host = text.split(separator: "/", maxSplits: 1).first.map(String.init) ?? text
        guard host.contains("."), !host.hasPrefix("."), !host.hasSuffix("."), host.allSatisfy({ $0.isLetter || $0.isNumber || ".-:".contains($0) }) else { return nil }
        return URL(string: "https://\(text)")
    }
}

struct CopyArcLinkAction: Action {
    let arc: ArcScripting
    let clipboard: any ClipboardService

    func run(_ invocation: Invocation) async throws {
        let tab = try await arc.activeTab()
        guard !tab.url.isEmpty else { throw ActionFailure("the current tab has no address") }
        await clipboard.writeText(Self.markdown(tab))
        invocation.result.report("Copied link to “\(tab.title.isEmpty ? tab.url : tab.title)”")
    }

    /// `[title](url)`, with brackets in the title escaped; the URL alone if there's no title.
    static func markdown(_ tab: ArcScripting.Link) -> String {
        guard !tab.title.isEmpty else { return "<\(tab.url)>" }
        let title = tab.title.replacingOccurrences(of: "[", with: "\\[").replacingOccurrences(of: "]", with: "\\]")
        let url = tab.url.replacingOccurrences(of: "(", with: "%28").replacingOccurrences(of: ")", with: "%29")
        return "[\(title)](\(url))"
    }
}

struct ChooseArcTabAction: Action {
    let arc: ArcScripting

    func run(_ invocation: Invocation) async throws {
        let tabs = try await arc.tabs()
        guard !tabs.isEmpty else { throw ActionFailure("Arc has no open tabs") }
        let choice = try await invocation.choose(ChoiceList(
            title: "Arc tabs", placeholder: "Search tabs",
            items: tabs.enumerated().map { index, tab in
                ChoiceItem(id: String(index), title: tab.title.isEmpty ? tab.url : tab.title, subtitle: Self.subtitle(tab), icon: .symbol("globe"))
            },
            primary: "Switch to Tab", secondary: "Close Tab"
        ))
        guard let index = Int(choice.itemID), tabs.indices.contains(index) else { return }
        switch choice.action {
        case .primary: try await arc.select(tabs[index])
        case .secondary:
            try await arc.close(tabs[index])
            invocation.result.report("Closed “\(tabs[index].title)”")
        }
    }

    /// The site, and where the tab sits if it's pinned or a favorite.
    static func subtitle(_ tab: ArcScripting.Tab) -> String {
        let host = URL(string: tab.url)?.host() ?? tab.url
        switch tab.location {
        case "pinned": return "\(host) · Pinned"
        case "topApp": return "\(host) · Favorite"
        default: return host
        }
    }
}

struct FocusArcSpaceAction: Action {
    let arc: ArcScripting
    let space: String

    func run(_ invocation: Invocation) async throws {
        try await arc.focusSpace(space)
    }
}
