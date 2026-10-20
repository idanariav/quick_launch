import CoreGraphics
import QLCore

/// A display, in Accessibility coordinates: origin at the top-left of the main
/// display, y growing downwards (AppKit uses bottom-left, y up).
struct Screen: Equatable, Sendable {
    let frame: CGRect
    /// Excludes the menu bar and Dock.
    let visibleFrame: CGRect

    init(frame: CGRect, visibleFrame: CGRect) {
        self.frame = frame
        self.visibleFrame = visibleFrame
    }

    /// Converts AppKit screen rects; `mainScreenHeight` is the height of `NSScreen.screens[0]`.
    init(appKitFrame: CGRect, appKitVisibleFrame: CGRect, mainScreenHeight: CGFloat) {
        func flip(_ rect: CGRect) -> CGRect {
            CGRect(x: rect.minX, y: mainScreenHeight - rect.maxY, width: rect.width, height: rect.height)
        }
        self.init(frame: flip(appKitFrame), visibleFrame: flip(appKitVisibleFrame))
    }
}

enum WindowOperation: String, ConfigEnum, Sendable {
    case leftHalf = "left_half"
    case rightHalf = "right_half"
    case topHalf = "top_half"
    case bottomHalf = "bottom_half"
    case topLeft = "top_left"
    case topRight = "top_right"
    case bottomLeft = "bottom_left"
    case bottomRight = "bottom_right"
    case maximize
    case center
    case nextDisplay = "next_display"
    case previousDisplay = "previous_display"

    var title: String {
        switch self {
        case .leftHalf: "Left Half"
        case .rightHalf: "Right Half"
        case .topHalf: "Top Half"
        case .bottomHalf: "Bottom Half"
        case .topLeft: "Top Left Quarter"
        case .topRight: "Top Right Quarter"
        case .bottomLeft: "Bottom Left Quarter"
        case .bottomRight: "Bottom Right Quarter"
        case .maximize: "Maximize"
        case .center: "Center"
        case .nextDisplay: "Next Display"
        case .previousDisplay: "Previous Display"
        }
    }

    var symbol: String {
        switch self {
        case .leftHalf: "rectangle.lefthalf.filled"
        case .rightHalf: "rectangle.righthalf.filled"
        case .topHalf: "rectangle.tophalf.filled"
        case .bottomHalf: "rectangle.bottomhalf.filled"
        case .topLeft: "rectangle.inset.topleft.filled"
        case .topRight: "rectangle.inset.topright.filled"
        case .bottomLeft: "rectangle.inset.bottomleft.filled"
        case .bottomRight: "rectangle.inset.bottomright.filled"
        case .maximize: "rectangle.fill"
        case .center: "rectangle.center.inset.filled"
        case .nextDisplay, .previousDisplay: "display.2"
        }
    }

    /// The fraction of the visible frame this operation fills (x, y, width, height), if it's a fixed region.
    fileprivate var region: CGRect? {
        switch self {
        case .leftHalf: CGRect(x: 0, y: 0, width: 0.5, height: 1)
        case .rightHalf: CGRect(x: 0.5, y: 0, width: 0.5, height: 1)
        case .topHalf: CGRect(x: 0, y: 0, width: 1, height: 0.5)
        case .bottomHalf: CGRect(x: 0, y: 0.5, width: 1, height: 0.5)
        case .topLeft: CGRect(x: 0, y: 0, width: 0.5, height: 0.5)
        case .topRight: CGRect(x: 0.5, y: 0, width: 0.5, height: 0.5)
        case .bottomLeft: CGRect(x: 0, y: 0.5, width: 0.5, height: 0.5)
        case .bottomRight: CGRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5)
        case .maximize: CGRect(x: 0, y: 0, width: 1, height: 1)
        case .center, .nextDisplay, .previousDisplay: nil
        }
    }
}

/// Where a window goes for each operation. Pure geometry, in Accessibility coordinates.
enum WindowLayout {
    enum Failure: Error, Equatable {
        case noScreens
        case onlyOneDisplay
    }

    static func frame(for operation: WindowOperation, window: CGRect, screens: [Screen]) throws(Failure) -> CGRect {
        guard let current = screen(containing: window, in: screens) else { throw .noScreens }
        let area = current.visibleFrame

        if let region = operation.region {
            return snappingEdges(CGRect(
                x: area.minX + region.minX * area.width,
                y: area.minY + region.minY * area.height,
                width: region.width * area.width,
                height: region.height * area.height
            ))
        }
        switch operation {
        case .center:
            let size = CGSize(width: min(window.width, area.width), height: min(window.height, area.height))
            return snappingOrigin(CGRect(x: area.midX - size.width / 2, y: area.midY - size.height / 2, width: size.width, height: size.height))
        case .nextDisplay, .previousDisplay:
            let ordered = screens.sorted { ($0.frame.minX, $0.frame.minY) < ($1.frame.minX, $1.frame.minY) }
            guard ordered.count > 1, let index = ordered.firstIndex(of: current) else { throw .onlyOneDisplay }
            let step = operation == .nextDisplay ? 1 : -1
            let target = ordered[(index + step + ordered.count) % ordered.count].visibleFrame
            return moved(window, from: area, to: target)
        default:
            preconditionFailure("\(operation) has a region")
        }
    }

    /// The screen showing most of the window; else the one under its center; else the main one.
    static func screen(containing window: CGRect, in screens: [Screen]) -> Screen? {
        let overlaps = screens.map { screen -> CGFloat in
            let overlap = screen.frame.intersection(window)
            return overlap.isNull ? 0 : overlap.width * overlap.height
        }
        if let best = overlaps.indices.max(by: { overlaps[$0] < overlaps[$1] }), overlaps[best] > 0 {
            return screens[best]
        }
        return screens.first { $0.frame.contains(CGPoint(x: window.midX, y: window.midY)) } ?? screens.first
    }

    /// Keeps the window's relative position and size, clamped to the target area.
    private static func moved(_ window: CGRect, from source: CGRect, to target: CGRect) -> CGRect {
        let width = min(window.width / source.width * target.width, target.width)
        let height = min(window.height / source.height * target.height, target.height)
        let x = target.minX + (window.minX - source.minX) / source.width * target.width
        let y = target.minY + (window.minY - source.minY) / source.height * target.height
        return snappingOrigin(CGRect(
            x: min(max(x, target.minX), target.maxX - width),
            y: min(max(y, target.minY), target.maxY - height),
            width: width.rounded(),
            height: height.rounded()
        ))
    }

    /// Rounds each edge to the nearest point, so adjacent regions (two halves) meet exactly.
    private static func snappingEdges(_ rect: CGRect) -> CGRect {
        let minX = rect.minX.rounded(), minY = rect.minY.rounded()
        return CGRect(x: minX, y: minY, width: rect.maxX.rounded() - minX, height: rect.maxY.rounded() - minY)
    }

    /// Rounds only the position, keeping the size.
    private static func snappingOrigin(_ rect: CGRect) -> CGRect {
        CGRect(origin: CGPoint(x: rect.minX.rounded(), y: rect.minY.rounded()), size: rect.size)
    }
}
