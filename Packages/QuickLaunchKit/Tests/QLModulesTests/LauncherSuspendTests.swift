import Foundation
import QLCore
import QLTesting
import Testing
@testable import QLModuleLauncher

/// Records input source switches; the current source starts as `hebrew`.
@MainActor
final class FakeInputSources: InputSourceSwitching {
    var current = "hebrew"
    var asciiCapable: Set<String> = ["abc"]

    func selectASCIICapable() -> String? {
        guard !asciiCapable.contains(current) else { return nil }
        defer { current = "abc" }
        return current
    }

    func select(_ id: String) {
        current = id
    }
}

/// `launcher.switch_to_english` and ⌘, (suspend and resume), decision 0022.
@MainActor
struct LauncherSuspendTests {
    private let commands = [Command(name: "safari", title: "Safari", action: NoopAction())]

    @Test func switchesToEnglishWhileOpenAndBackWhenItHides() {
        let sources = FakeInputSources()
        let (launcher, _, _) = makeLauncher(inputSources: sources)
        launcher.showSearch()
        #expect(sources.current == "hebrew") // off by default

        launcher.dismiss()
        launcher.switchesToEnglish = true
        launcher.showSearch()
        #expect(sources.current == "abc")
        launcher.dismiss()
        #expect(sources.current == "hebrew")
    }

    @Test func anASCIISourceIsLeftAlone() {
        let sources = FakeInputSources()
        sources.current = "abc"
        let (launcher, _, _) = makeLauncher(inputSources: sources)
        launcher.switchesToEnglish = true
        launcher.showSearch()
        sources.current = "dvorak" // the user picked another one meanwhile
        launcher.dismiss()
        #expect(sources.current == "dvorak")
    }

    @Test func theSwitchIsReadFromTheConfig() throws {
        let (launcher, _, _) = makeLauncher()
        let store = ConfigStore(
            source: FakeConfigSource(yaml: "launcher: { switch_to_english: true }"), loader: ConfigLoader(modules: [LauncherModule(launcher: launcher)])
        )
        #expect(!launcher.switchesToEnglish)
        store.start()
        #expect(launcher.switchesToEnglish)
    }

    @Test func resumeShowsTheSearchSuspendLeftForTheSameApp() async throws {
        let frontmost = FakeFrontmostApp(bundleID: "com.user.app")
        let (launcher, _, runner) = makeLauncher(commands, frontmost: frontmost)
        launcher.showSearch(scope: .favorites)
        launcher.query = "saf"
        #expect(launcher.suspend())
        #expect(!launcher.isVisible)

        frontmost.activate("ql") // the settings window had focus
        launcher.resume()
        #expect(launcher.isVisible)
        #expect(launcher.query == "saf")
        #expect(launcher.scope == .favorites)

        // Runs still act on the app the user came from.
        launcher.showSearch()
        launcher.query = "saf"
        #expect(launcher.suspend())
        launcher.resume()
        #expect(await eventually { !launcher.results.isEmpty })
        launcher.runSelected()
        var requests: [RunRequest] = []
        for _ in 0..<200 where requests.isEmpty {
            requests = await runner.requests
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(requests.first?.frontmostApp?.bundleID == "com.user.app")
    }

    @Test func onlySearchCanBeSuspended() {
        let (launcher, _, _) = makeLauncher()
        #expect(!launcher.suspend()) // not open
        launcher.resume() // nothing to resume
        #expect(!launcher.isVisible)
    }
}
