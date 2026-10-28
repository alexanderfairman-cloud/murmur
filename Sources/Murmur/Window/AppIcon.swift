import AppKit
import SwiftUI

/// The Dock icon: the same dark pill and white waveform as the floating bar, on a rounded square.
struct MurmurIconArt: View {
    var body: some View {
        GeometryReader { geo in
            let side = geo.size.width
            // macOS app icons leave a margin around the shape.
            let tile = side * 0.805
            ZStack {
                RoundedRectangle(cornerRadius: tile * 0.225, style: .continuous)
                    .fill(LinearGradient(colors: [Color(white: 0.17), Color(white: 0.05)], startPoint: .top, endPoint: .bottom))
                    .frame(width: tile, height: tile)
                    .overlay(
                        RoundedRectangle(cornerRadius: tile * 0.225, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.14), lineWidth: max(1, side * 0.004))
                            .frame(width: tile, height: tile))
                HStack(spacing: tile * 0.045) {
                    ForEach(Array([0.16, 0.32, 0.56, 0.36, 0.7, 0.4, 0.22, 0.12].enumerated()), id: \.offset) { _, h in
                        Capsule()
                            .fill(Color.white.opacity(0.55 + 0.45 * h))
                            .frame(width: tile * 0.052, height: tile * 0.62 * h)
                    }
                }
            }
            .frame(width: side, height: side)
        }
    }
}

enum IconRenderer {
    /// Writes every size macOS wants into an `.iconset` folder, ready for `iconutil`.
    @MainActor
    static func render(into folder: String) -> Bool {
        let directory = URL(fileURLWithPath: folder)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let sizes: [(String, Int)] = [
            ("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
            ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512),
            ("icon_512x512", 512), ("icon_512x512@2x", 1024),
        ]
        for (name, pixels) in sizes {
            let renderer = ImageRenderer(content: MurmurIconArt().frame(width: CGFloat(pixels), height: CGFloat(pixels)))
            renderer.scale = 1
            guard let tiff = renderer.nsImage?.tiffRepresentation,
                  let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
            else { return false }
            do { try png.write(to: directory.appendingPathComponent("\(name).png")) } catch { return false }
        }
        return true
    }
}
