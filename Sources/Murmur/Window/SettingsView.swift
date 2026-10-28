import MurmurCore
import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: AppModel

    /// Keeps a paragraph pause at least a little longer than a sentence pause.
    private var sentencePause: Binding<Double> {
        Binding(
            get: { model.settings.sentencePause },
            set: {
                model.settings.sentencePause = $0
                if model.settings.paragraphPause < $0 + 0.2 { model.settings.paragraphPause = ($0 + 0.2 * 10).rounded() / 10 }
            })
    }

    private var paragraphPause: Binding<Double> {
        Binding(
            get: { model.settings.paragraphPause },
            set: { model.settings.paragraphPause = max($0, model.settings.sentencePause + 0.2) })
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                group("Dictation key") {
                    VStack(alignment: .leading, spacing: 8) {
                        Picker("Dictation key", selection: $model.settings.hotkey) {
                            ForEach(HotkeyChoice.allCases, id: \.self) { Text(AppModel.keyName($0)).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        Text("Hold it to talk. Hold it and tap Space to keep listening hands-free.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .padding(12)
                }

                group("While you dictate") {
                    row("Play a sound when listening starts and stops") { Toggle("", isOn: $model.settings.sounds) }
                    divider
                    row("Add a space after each dictation") { Toggle("", isOn: $model.settings.trailingSpace) }
                    divider
                    row("Remove \u{201C}um\u{201D} and \u{201C}uh\u{201D}") { Toggle("", isOn: $model.settings.removeFillers) }
                }

                group("Pauses") {
                    row("Turn long pauses into sentences and paragraphs") { Toggle("", isOn: $model.settings.pauseBreaks) }
                    if model.settings.pauseBreaks {
                        divider
                        row("A pause this long ends a sentence") {
                            HStack(spacing: 8) {
                                Slider(value: sentencePause, in: 0.4...2.0, step: 0.1).frame(width: 130)
                                Text(seconds(model.settings.sentencePause)).font(.system(size: 12).monospacedDigit()).frame(width: 40, alignment: .trailing)
                            }
                        }
                        divider
                        row("A pause this long starts a paragraph") {
                            HStack(spacing: 8) {
                                Slider(value: paragraphPause, in: 1.0...4.0, step: 0.1).frame(width: 130)
                                Text(seconds(model.settings.paragraphPause)).font(.system(size: 12).monospacedDigit()).frame(width: 40, alignment: .trailing)
                            }
                        }
                    }
                }

                group("This Mac") {
                    row("Open Murmur when you log in") {
                        Toggle("", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
                    }
                    divider
                    row("Your dictations, words and settings stay in a folder on this Mac") {
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([model.files.directory]) }
                            .buttonStyle(QuietButtonStyle())
                    }
                }
            }
            .frame(maxWidth: 560, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.top, 38)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity)
        }
        .toggleStyle(.switch)
    }

    private func seconds(_ value: Double) -> String { String(format: "%.1f s", value) }

    private var divider: some View {
        Rectangle().fill(Theme.hairline).frame(height: 0.5).padding(.leading, 12)
    }

    private func row<Control: View>(_ title: String, @ViewBuilder control: () -> Control) -> some View {
        HStack(spacing: 12) {
            Text(title).font(.system(size: 13)).frame(maxWidth: .infinity, alignment: .leading)
            control().labelsHidden()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary).padding(.leading, 4)
            VStack(spacing: 0, content: content)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.fill))
        }
    }
}
