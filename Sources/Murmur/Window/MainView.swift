import SwiftUI

/// The Murmur window: a narrow sidebar, and the screen you picked.
struct MainView: View {
    @ObservedObject var model: AppModel
    /// Dictations that start opened, and ones that start mid-fix. Only the picture-taking check uses these.
    var historyOpen: Set<UUID> = []
    var historyFix: [UUID: FixState] = [:]

    var body: some View {
        HStack(spacing: 0) {
            Sidebar(model: model)
                .frame(width: 88)
                .background(Color.primary.opacity(0.03))
            Divider()
            Group {
                switch model.tab {
                case .history: HistoryView(model: model, open: historyOpen, fixStart: historyFix)
                case .words: WordsView(model: model)
                case .settings: SettingsView(model: model)
                }
            }
            .id(model.tab)
            .transition(.opacity)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .animation(.easeOut(duration: 0.12), value: model.tab)
        .background(Color(nsColor: .windowBackgroundColor))
        .ignoresSafeArea()
    }
}

private struct Sidebar: View {
    @ObservedObject var model: AppModel

    private var today: Int {
        model.historyItems.filter { Calendar.current.isDateInToday($0.date) }.count
    }

    var body: some View {
        VStack(spacing: 4) {
            item(.history, "clock.arrow.circlepath", "History", badge: today)
            item(.words, "character.book.closed", "Words", badge: model.words.entries.count)
            Spacer()
            status
            item(.settings, "gearshape", "Settings", badge: nil)
        }
        .padding(.horizontal, 8)
        .padding(.top, 40)
        .padding(.bottom, 10)
    }

    private func item(_ tab: AppModel.Tab, _ icon: String, _ label: String, badge: Int?) -> some View {
        Button {
            model.tab = tab
        } label: {
            VStack(spacing: 3) {
                Image(systemName: icon).font(.system(size: 18))
                Text(label).font(.system(size: 11))
            }
            .foregroundStyle(model.tab == tab ? Color.primary : Color.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(model.tab == tab ? Color.primary.opacity(0.09) : .clear))
            .overlay(alignment: .topTrailing) {
                if let badge, badge > 0 {
                    Text("\(badge)")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .frame(minWidth: 16, minHeight: 16)
                        .background(Capsule().fill(Theme.accent))
                        .offset(x: -3, y: 3)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    /// One small readout: the dictation key, and whether dictation works right now.
    private var status: some View {
        let (color, word): (Color, String) = switch model.health {
        case .ready: (Theme.ok, "Ready")
        case .setup: (Theme.warn, "Setup")
        case .failed: (Theme.bad, "Error")
        }
        return Button {
            model.tab = .history
        } label: {
            VStack(spacing: 5) {
                KeyCap(text: model.settings.hotkey == .fn ? "Fn" : String(model.keyName.last ?? "?"))
                HStack(spacing: 4) {
                    StatusDot(color: color)
                    Text(word).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(model.statusLine)
        .accessibilityLabel(model.statusLine)
    }
}

/// The first-run checklist. It is only on screen while something is still missing.
struct SetupCard: View {
    @ObservedObject var model: AppModel

    private var allowed: Int { Permission.allCases.filter { model.granted[$0] == true }.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(model.health == .failed ? "Something needs fixing" : "Almost ready")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Text("\(allowed) of \(Permission.allCases.count)")
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            ProgressTrack(fraction: Double(allowed) / Double(Permission.allCases.count))
                .frame(height: 4)
                .padding(.top, 8)
                .padding(.bottom, 6)
            ForEach(Permission.allCases) { permission in
                row(icon: icon(permission), title: permission.title, detail: detail(permission)) {
                    if model.granted[permission] == true {
                        Label("Allowed", systemImage: "checkmark").font(.system(size: 12)).foregroundStyle(Theme.ok)
                    } else {
                        HStack(spacing: 8) {
                            // macOS tells a running app about Accessibility and Input Monitoring changes only at its next
                            // start (a running copy keeps its earlier "no"), so offer a restart as soon as Allow was clicked.
                            if permission != .microphone, model.tried.contains(permission) {
                                Button("Restart Murmur") { model.relaunch() }.buttonStyle(QuietButtonStyle())
                            }
                            Button("Allow") { model.allow(permission) }.buttonStyle(PrimaryButtonStyle())
                        }
                    }
                }
            }
            if model.settings.hotkey == .fn { globeRow }
            modelRow
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.fill))
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in model.refreshPermissions() }
    }

    /// What the permission is for. Once someone has tried to switch it on and it still does not register,
    /// this says what to do, because macOS gives no hint of its own.
    private func detail(_ permission: Permission) -> String {
        guard model.tried.contains(permission), model.granted[permission] != true else {
            return String(permission.reason.prefix(1)).uppercased() + String(permission.reason.dropFirst())
        }
        switch permission {
        case .microphone:
            return "Still off. Turn Murmur on in the Microphone list in System Settings."
        case .accessibility, .inputMonitoring:
            return "Switched it on already? Click Restart Murmur. Still stuck? Remove Murmur with the minus button, then click Allow."
        }
    }

    private func icon(_ permission: Permission) -> String {
        switch permission {
        case .microphone: "mic"
        case .accessibility: "keyboard"
        case .inputMonitoring: "keyboard.badge.eye"
        }
    }

    private var globeRow: some View {
        row(icon: "globe", title: "Globe key", detail: "Set it to Do Nothing, or macOS opens emoji when you let go of Fn") {
            if model.globeKeyDoesNothing {
                Label("Set", systemImage: "checkmark").font(.system(size: 12)).foregroundStyle(Theme.ok)
            } else {
                // Not green when unknown: the app cannot see what the setting is unless it is already Do Nothing.
                Button("Open") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(QuietButtonStyle())
            }
        }
    }

    private var modelRow: some View {
        row(icon: "waveform", title: "Speech model", detail: modelDetail) {
            switch model.modelStatus {
            case .ready:
                Label("Ready", systemImage: "checkmark").font(.system(size: 12)).foregroundStyle(Theme.ok)
            case .loading(let fraction, let downloading):
                if downloading {
                    HStack(spacing: 8) {
                        ProgressTrack(fraction: fraction).frame(width: 90, height: 4)
                        Text("\(Int(fraction * 100))%").font(.system(size: 12).monospacedDigit()).foregroundStyle(.secondary)
                    }
                } else {
                    Text("Starting up…").font(.system(size: 12)).foregroundStyle(.secondary)
                }
            case .failed:
                Text("Could not load").font(.system(size: 12)).foregroundStyle(Theme.bad)
            }
        }
    }

    private var modelDetail: String {
        if case .failed = model.modelStatus { return "Check your internet, then restart Murmur" }
        return "Downloaded once, then works offline"
    }

    private func row<Trailing: View>(
        icon: String, title: String, detail: String, @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 14)).foregroundStyle(.secondary).frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            trailing()
        }
        .padding(.vertical, 7)
    }
}
