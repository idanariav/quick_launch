import AppKit
import QLCore
import SwiftUI

// The views every surface builds from (decision 0020).

/// A command's icon: an app's own icon, or a symbol on a tile the same size, so rows
/// with either look alike.
struct IconTile: View {
    let icon: CommandIcon?
    var size: CGFloat = Theme.Size.icon

    var body: some View {
        switch icon {
        case .file(let path):
            Image(nsImage: IconCache.icon(forFile: path)).resizable().aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
        case .symbol(let name):
            symbol(name)
        case nil:
            symbol("command")
        }
    }

    /// App icons leave a margin inside their image, so the tile is inset to match.
    private func symbol(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: size * 0.46, weight: .medium))
            .foregroundStyle(.secondary)
            .frame(width: size * 0.84, height: size * 0.84)
            .background(Theme.Palette.fill, in: RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
            .frame(width: size, height: size)
    }
}

@MainActor
enum IconCache {
    private static var icons: [String: NSImage] = [:]

    static func icon(forFile path: String) -> NSImage {
        if let icon = icons[path] { return icon }
        let icon = NSWorkspace.shared.icon(forFile: path)
        icons[path] = icon
        return icon
    }
}

/// How a run is going, in the HUD and the output header.
struct StatusIcon: View {
    enum Status {
        case running, success, failure
    }

    let status: Status

    var body: some View {
        switch status {
        case .running: ProgressView().controlSize(.small)
        case .success: Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.Palette.success)
        case .failure: Image(systemName: "xmark.octagon.fill").foregroundStyle(Theme.Palette.failure)
        }
    }
}

/// A key or key combination, drawn as a key.
struct Keycap: View {
    let keys: String

    var body: some View {
        Text(keys)
            .font(Theme.Typography.captionEmphasized)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .frame(minWidth: 18, minHeight: 18)
            .background(Theme.Palette.fill, in: RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
    }
}

struct KeyHint: Hashable {
    let keys: String
    let label: String

    init(_ keys: String, _ label: String) {
        self.keys = keys
        self.label = label
    }
}

/// The footer under every launcher mode: a note on the left, what the keys do on the right.
struct ActionBar: View {
    var note: String?
    let hints: [KeyHint]

    var body: some View {
        HStack(spacing: Theme.Spacing.m) {
            if let note {
                Text(note).font(Theme.Typography.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
            }
            Spacer(minLength: Theme.Spacing.m)
            ForEach(hints, id: \.self) { hint in
                HStack(spacing: Theme.Spacing.xs + 1) {
                    Text(hint.label).font(Theme.Typography.caption).foregroundStyle(.secondary)
                    Keycap(keys: hint.keys)
                }
            }
        }
        .padding(.horizontal, Theme.Spacing.l)
        .frame(height: Theme.Size.actionBar)
        .background(Theme.Palette.fill.opacity(0.5))
    }
}

/// A title bar for a panel that isn't a search: a form or an output.
struct PanelHeader<Accessory: View>: View {
    var status: StatusIcon.Status?
    let title: String
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(spacing: Theme.Spacing.s) {
            if let status { StatusIcon(status: status) }
            Text(title).font(Theme.Typography.titleEmphasized).lineLimit(1)
            Spacer()
            accessory
        }
        .padding(.horizontal, Theme.Spacing.l)
        .frame(height: Theme.Size.header)
    }
}

extension PanelHeader where Accessory == EmptyView {
    init(status: StatusIcon.Status? = nil, title: String) {
        self.init(status: status, title: title) { EmptyView() }
    }
}

/// A label in a fixed column, then its control; a note or an error goes under the control.
struct FieldRow<Control: View>: View {
    let label: String
    var note: String?
    var error: String?
    @ViewBuilder var control: Control

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.s) {
                Text(label).font(Theme.Typography.body).foregroundStyle(.secondary)
                    .frame(width: Theme.Size.labelColumn, alignment: .leading)
                control
                Spacer(minLength: 0)
            }
            Group {
                if let note { Text(note).foregroundStyle(.secondary) }
                if let error { Text(error).foregroundStyle(Theme.Palette.failure) }
            }
            .font(Theme.Typography.caption)
            .padding(.leading, Theme.Size.labelColumn + Theme.Spacing.s)
        }
    }
}

/// What a list shows when it has nothing to show.
struct EmptyState: View {
    let text: String

    var body: some View {
        Text(text).font(Theme.Typography.body).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .frame(height: Theme.Size.row)
    }
}

/// A small rounded label, e.g. a matched alias or the list a choice belongs to.
struct Chip: View {
    let text: String

    var body: some View {
        Text(text).font(Theme.Typography.captionEmphasized)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Theme.Palette.fill, in: RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
    }
}

extension View {
    /// The material card of the launcher and the HUD.
    func panelCard(shadow: Bool = true) -> some View {
        background(.regularMaterial, in: RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous).strokeBorder(Theme.Palette.cardStroke))
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous))
            .shadow(color: .black.opacity(shadow ? 0.35 : 0), radius: 18, y: 8)
    }
}
