import SwiftUI

/// The values every surface shares (decision 0020). Views use these, not literal sizes.
enum Theme {
    enum Spacing {
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 20
    }

    enum Radius {
        /// The launcher card and the HUD.
        static let panel: CGFloat = 14
        /// A selected row.
        static let row: CGFloat = 8
        /// Keycaps and chips.
        static let small: CGFloat = 5
    }

    /// The type scale.
    enum Typography {
        /// The launcher's main field: search, or a form's text input.
        static let field = Font.system(size: 20)
        /// The value on the launcher's answer card (decision 0030).
        static let answer = Font.system(size: 22, weight: .semibold)
        /// Row titles and panel headers.
        static let title = Font.system(size: 14)
        static let titleEmphasized = Font.system(size: 14, weight: .semibold)
        /// Form fields, output and the HUD.
        static let body = Font.system(size: bodySize)
        /// For AppKit views, e.g. the snippet text view.
        static let bodySize: CGFloat = 13
        /// Subtitles, hints, kind labels and section headers.
        static let caption = Font.system(size: 11)
        static let captionEmphasized = Font.system(size: 11, weight: .semibold)
    }

    enum Size {
        static let searchBar: CGFloat = 56
        static let header: CGFloat = 48
        static let actionBar: CGFloat = 32
        static let row: CGFloat = 44
        static let groupHeader: CGFloat = 26
        /// The launcher's answer card, between the field and the results (decision 0030).
        static let answer: CGFloat = 60
        /// A row's icon, in the launcher and the Settings header.
        static let icon: CGFloat = 28
        /// The Settings sidebar's icons.
        static let smallIcon: CGFloat = 18
        /// Where controls start after their label.
        static let labelColumn: CGFloat = 120
        /// Lists and output grow up to this, then scroll.
        static let maxContent: CGFloat = 400
    }

    enum Palette {
        static let selection = Color.accentColor.opacity(0.25)
        /// Icon tiles, keycaps and chips.
        static let fill = Color.primary.opacity(0.08)
        static let cardStroke = Color.white.opacity(0.12)
        static let success = Color.green
        static let failure = Color.red
        static let warning = Color.yellow
    }
}
