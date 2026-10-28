import AppKit
import SwiftUI

@MainActor
final class HUDModel: ObservableObject {
    enum Mode: Equatable {
        /// Hidden and at rest. Draws nothing, so a hidden bar costs no CPU.
        case idle
        case listening(locked: Bool)
        case thinking
        case message(String)
        case download(Double)
    }

    static let barCount = 26

    @Published var mode: Mode = .idle
    @Published var levels: [Float] = Array(repeating: 0, count: HUDModel.barCount)

    /// Adds the newest loudness reading; older ones slide to the left.
    func push(rms: Float) {
        // Speech sits around 0.01 to 0.1. The square root stretches the quiet end so soft voices still move the bars.
        let level = min(1, rms.squareRoot() * 2.4)
        levels.removeFirst()
        levels.append(level)
    }

    func clearLevels() {
        levels = Array(repeating: 0, count: Self.barCount)
    }
}

struct HUDView: View {
    @ObservedObject var model: HUDModel

    var body: some View {
        content
            .padding(.horizontal, 18)
            .frame(height: 40)
            .background(Capsule().fill(Color.black.opacity(0.92)))
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
            .shadow(color: .black.opacity(0.4), radius: 12, y: 4)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .animation(.spring(response: 0.28, dampingFraction: 0.86), value: model.mode)
    }

    @ViewBuilder
    private var content: some View {
        switch model.mode {
        case .idle:
            Color.clear.frame(width: 0, height: 0)
        case .listening(let locked):
            HStack(spacing: 10) {
                if locked {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.8))
                }
                Waveform(levels: model.levels)
            }
        case .thinking:
            Spinner()
                .frame(width: 60)
        case .message(let text):
            Text(text)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white)
                .lineLimit(1)
        case .download(let fraction):
            HStack(spacing: 10) {
                Text("Getting the speech model")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white)
                ProgressBar(fraction: fraction)
                    .frame(width: 90, height: 5)
                Text("\(Int(fraction * 100))%")
                    .font(.system(size: 13, weight: .medium).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.8))
            }
        }
    }
}

private struct ProgressBar: View {
    let fraction: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.2))
                Capsule().fill(Color.white).frame(width: geo.size.width * min(1, max(0, fraction)))
            }
        }
    }
}

/// A small turning arc, shown for the fraction of a second while the words are being worked out.
private struct Spinner: View {
    var body: some View {
        TimelineView(.animation) { timeline in
            let angle = timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 0.9) / 0.9 * 360
            Circle()
                .trim(from: 0, to: 0.7)
                .stroke(Color.white, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .frame(width: 16, height: 16)
                .rotationEffect(.degrees(angle))
        }
    }
}

private struct Waveform: View {
    let levels: [Float]

    var body: some View {
        HStack(spacing: 3) {
            ForEach(levels.indices, id: \.self) { i in
                Capsule()
                    .fill(Color.white.opacity(0.5 + 0.5 * Double(levels[i])))
                    .frame(width: 3, height: 4 + CGFloat(levels[i]) * 22)
            }
        }
        .frame(height: 26)
        .animation(.linear(duration: 0.06), value: levels)
    }
}

/// The small dark pill at the bottom of the screen. It never takes focus, so your cursor stays where it was.
@MainActor
final class HUDController {
    private let model = HUDModel()
    private var hideTask: Task<Void, Never>?
    private lazy var panel: NSPanel = makePanel()

    func listening(locked: Bool) {
        hideTask?.cancel()
        if case .listening = model.mode {} else { model.clearLevels() }
        model.mode = .listening(locked: locked)
        show()
    }

    func thinking() {
        hideTask?.cancel()
        model.mode = .thinking
        show()
    }

    func progress(_ fraction: Double) {
        hideTask?.cancel()
        model.mode = .download(fraction)
        show()
    }

    func message(_ text: String, seconds: Double = 2.6) {
        hideTask?.cancel()
        model.mode = .message(text)
        show()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            if !Task.isCancelled { self?.hide() }
        }
    }

    func level(_ rms: Float) {
        model.push(rms: rms)
    }

    func hide() {
        hideTask?.cancel()
        guard panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.16
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.panel.alphaValue == 0 else { return }
                self.panel.orderOut(nil)
                // A hidden spinner keeps redrawing the screen 60 times a second unless it is taken out of the view.
                self.model.mode = .idle
            }
        })
    }

    // MARK: -

    private func show() {
        position()
        if !panel.isVisible { panel.alphaValue = 0 }
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            panel.animator().alphaValue = 1
        }
    }

    /// Bottom centre of the screen you are working on, just above the Dock.
    private func position() {
        let screen = NSScreen.main ?? NSScreen.screens.first
        guard let frame = screen?.visibleFrame else { return }
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2, y: frame.minY + 6))
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 72),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.contentView = NSHostingView(rootView: HUDView(model: model))
        return panel
    }
}
