import AppKit
import SwiftUI

/// Colours and shapes used across the window. One accent; green, amber and red only ever mean status.
enum Theme {
    static let accent = Color(red: 0.145, green: 0.388, blue: 0.922)
    static let accentTop = Color(red: 0.26, green: 0.56, blue: 0.99)
    static let ok = Color(red: 0.13, green: 0.62, blue: 0.33)
    static let warn = Color(red: 0.88, green: 0.56, blue: 0.05)
    static let bad = Color(red: 0.84, green: 0.22, blue: 0.22)
    static let hairline = Color.primary.opacity(0.10)
    static let hover = Color.primary.opacity(0.045)
    static let fill = Color.primary.opacity(0.055)
}

/// The one bright button on a screen.
struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(LinearGradient(colors: [Theme.accentTop, Theme.accent], startPoint: .top, endPoint: .bottom)))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.white.opacity(0.2), lineWidth: 0.5))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }
}

/// Everything else you can press.
struct QuietButtonStyle: ButtonStyle {
    var tint: Color = .primary

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 11)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.fill))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }
}

/// A small icon-only button.
struct IconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13))
            .frame(width: 26, height: 26)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(configuration.isPressed ? Theme.fill : .clear))
            .contentShape(Rectangle())
    }
}

/// A keyboard key, drawn as a key.
struct KeyCap: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color.primary.opacity(0.22), lineWidth: 0.5))
            .overlay(alignment: .bottom) {
                Capsule().fill(Color.primary.opacity(0.22)).frame(height: 1.5).padding(.horizontal, 3).offset(y: 0.5)
            }
    }
}

struct StatusDot: View {
    let color: Color

    var body: some View {
        Circle().fill(color).frame(width: 7, height: 7)
    }
}

/// A bar that fills as a process moves along.
struct ProgressTrack: View {
    let fraction: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.hairline)
                Capsule().fill(Theme.accent).frame(width: geo.size.width * min(1, max(0, fraction)))
            }
        }
        .animation(.easeOut(duration: 0.25), value: fraction)
    }
}

/// The text box used for searching.
struct SearchBar: View {
    @Binding var text: String
    let prompt: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary).font(.system(size: 12))
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.fill))
    }
}

/// Lays small items out in rows that wrap, like words in a paragraph.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(width: proposal.width ?? .infinity, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(width: bounds.width, subviews: subviews)
        for (index, origin) in result.origins.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y), proposal: .unspecified)
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> (size: CGSize, origins: [CGPoint]) {
        var origins: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            origins.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return (CGSize(width: widest, height: y + rowHeight), origins)
    }
}

/// An app's real icon, as macOS shows it. A lettered tile stands in when the app is not installed any more.
struct AppIconView: View {
    let appID: String?
    let name: String?
    var size: CGFloat = 22

    private static var cache: [String: NSImage] = [:]

    private static func icon(for id: String) -> NSImage? {
        if let cached = cache[id] { return cached }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return nil }
        let image = NSWorkspace.shared.icon(forFile: url.path)
        cache[id] = image
        return image
    }

    var body: some View {
        if let appID, let image = Self.icon(for: appID) {
            Image(nsImage: image).resizable().frame(width: size, height: size)
        } else {
            Text(String((name ?? "?").prefix(1)).uppercased())
                .font(.system(size: size * 0.5, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: size, height: size)
                .background(RoundedRectangle(cornerRadius: size * 0.24, style: .continuous).fill(Theme.fill))
        }
    }
}

extension Permission: Identifiable {
    var id: Self { self }
}
