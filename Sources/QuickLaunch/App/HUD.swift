import AppKit
import QLCore
import SwiftUI

/// Shows feedback for headless runs as a toast near the bottom of the screen with
/// the pointer. It never takes focus or mouse events.
@MainActor
final class HUDController: FeedbackPresenting {
    private static let successDuration: Duration = .seconds(1.5)
    private static let failureDuration: Duration = .seconds(3.5)
    /// Text wraps beyond this width; shorter messages shrink the HUD to fit.
    private static let maxWidth: CGFloat = 480

    private lazy var hosting: NSHostingController<HUDView> = {
        let hosting = NSHostingController(rootView: HUDView(style: .running, message: ""))
        hosting.sizingOptions = [] // the panel is sized in position(), not by SwiftUI
        return hosting
    }()
    private lazy var panel = makePanel()
    /// The run whose state is on screen.
    private var shownRun: UUID?
    /// Bumped on every change, so a stale auto-hide or fade-out doesn't hide newer content.
    private var generation = 0

    func update(run: UUID, state: RunState) async {
        switch state {
        case .running(let title):
            show(.running, title, for: run, hideAfter: nil)
        case .succeeded(nil):
            if shownRun == run { hide() }
        case .succeeded(let message?):
            show(.success, message, for: run, hideAfter: Self.successDuration)
        case .failed(let message):
            show(.failure, message, for: run, hideAfter: Self.failureDuration)
        }
    }

    private func show(_ style: HUDView.Style, _ message: String, for run: UUID, hideAfter: Duration?) {
        generation += 1
        let token = generation
        shownRun = run
        // A new root view (not an observable model) so the measurement below sees this message.
        hosting.rootView = HUDView(style: style, message: message)
        position()
        panel.alphaValue = 1
        panel.orderFrontRegardless()

        if let hideAfter {
            Task {
                try? await Task.sleep(for: hideAfter)
                if generation == token { hide() }
            }
        }
    }

    private func hide() {
        generation += 1
        let token = generation
        shownRun = nil
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            panel.animator().alphaValue = 0
        } completionHandler: {
            MainActor.assumeIsolated {
                if self.generation == token { self.panel.orderOut(nil) }
            }
        }
    }

    private func position() {
        // Natural size, wrapping only past maxWidth (fittingSize would wrap at the minimum width).
        let size = hosting.sizeThatFits(in: CGSize(width: Self.maxWidth, height: .greatestFiniteMagnitude))
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }
        panel.setFrame(
            NSRect(x: frame.midX - size.width / 2, y: frame.minY + 96, width: size.width, height: size.height),
            display: true
        )
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.contentViewController = hosting
        return panel
    }
}

struct HUDView: View {
    enum Style {
        case running, success, failure
    }

    let style: Style
    let message: String

    var body: some View {
        HStack(spacing: 10) {
            switch style {
            case .running:
                ProgressView().controlSize(.small)
            case .success:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case .failure:
                Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
            }
            Text(message)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
