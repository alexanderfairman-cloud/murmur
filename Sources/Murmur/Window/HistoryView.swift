import MurmurCore
import SwiftUI

struct HistoryView: View {
    @ObservedObject var model: AppModel
    @State private var query = ""
    @State private var open: Set<UUID>
    private let fixStart: [UUID: FixState]

    /// `open` and `fixStart` only matter for the picture-taking check, which draws rows already opened or mid-fix.
    init(model: AppModel, open: Set<UUID> = [], fixStart: [UUID: FixState] = [:]) {
        self.model = model
        self.fixStart = fixStart
        _open = State(initialValue: open)
    }

    private var matches: [HistoryItem] { model.historyItems.filter { $0.matches(query) } }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 10) {
                if !model.setupComplete { SetupCard(model: model) }
                if !model.historyItems.isEmpty { SearchBar(text: $query, prompt: "Search your dictations") }
            }
            .padding(.horizontal, 20)
            .padding(.top, 38)
            .padding(.bottom, 6)

            if model.historyItems.isEmpty {
                EmptyHistory(keyName: model.keyName)
            } else if matches.isEmpty {
                Text("Nothing matches \u{201C}\(query)\u{201D}.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                list
            }
        }
    }

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(HistoryGrouping.days(matches)) { day in
                    Text(day.title)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.top, 14)
                        .padding(.bottom, 4)
                        .padding(.horizontal, 8)
                    ForEach(day.items) { item in
                        HistoryRow(
                            item: item,
                            model: model,
                            fix: fixStart[item.id] ?? .idle,
                            isOpen: open.contains(item.id),
                            toggle: {
                                withAnimation(.snappy(duration: 0.18)) {
                                    if open.contains(item.id) { open.remove(item.id) } else { open.insert(item.id) }
                                }
                            },
                            delete: {
                                withAnimation(.snappy(duration: 0.18)) {
                                    open.remove(item.id)
                                    model.deleteDictations([item.id])
                                }
                            })
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 16)
        }
    }
}

private struct EmptyHistory: View {
    let keyName: String

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 3) {
                ForEach([8, 14, 24, 12, 20, 9, 5], id: \.self) { height in
                    Capsule().fill(Color.primary.opacity(0.18)).frame(width: 3, height: CGFloat(height))
                }
            }
            .frame(height: 26)
            HStack(spacing: 6) {
                Text("Hold").font(.system(size: 14, weight: .medium))
                KeyCap(text: keyName)
                Text("and talk").font(.system(size: 14, weight: .medium))
            }
            Text("Your dictations show up here.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.bottom, 40)
    }
}

private struct HistoryRow: View {
    let item: HistoryItem
    let model: AppModel
    let isOpen: Bool
    let toggle: () -> Void
    let delete: () -> Void

    @State private var hovering = false
    @State private var copied = false
    @State private var confirmingDelete = false
    @State private var fix: FixState

    init(item: HistoryItem, model: AppModel, fix: FixState, isOpen: Bool, toggle: @escaping () -> Void, delete: @escaping () -> Void) {
        self.item = item
        self.model = model
        self.isOpen = isOpen
        self.toggle = toggle
        self.delete = delete
        _fix = State(initialValue: fix)
    }

    private var oneLine: String {
        item.text.split(whereSeparator: \.isNewline).joined(separator: " ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if isOpen { details }
        }
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(hovering || isOpen ? Theme.hover : .clear))
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairline).frame(height: 0.5).padding(.horizontal, 8) }
        .onHover { hovering = $0 }
        .onChange(of: isOpen) { _, nowOpen in if !nowOpen { fix = .idle } }
    }

    private var header: some View {
        HStack(spacing: 10) {
            AppIconView(appID: item.appID, name: item.app)
            Text(item.date.formatted(date: .omitted, time: .shortened))
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 62, alignment: .leading)
            if isOpen {
                Text(item.app ?? "Unknown app")
                    .font(.system(size: 12, weight: .medium))
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text(oneLine)
                    .font(.system(size: 13))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if !item.corrections.isEmpty {
                    Text(item.corrections.count == 1 ? "1 fix" : "\(item.corrections.count) fixes")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.accent)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Theme.accent.opacity(0.12)))
                }
            }
            copyButton
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onTapGesture(perform: toggle)
    }

    /// Always visible, only quieter at rest, so it works on a trackpad and with a mouse alike.
    private var copyButton: some View {
        Button {
            TextInjector.copy(item.text)
            copied = true
            Task {
                try? await Task.sleep(for: .seconds(1))
                copied = false
            }
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .foregroundStyle(copied ? Theme.ok : Color.secondary)
                .opacity(hovering || isOpen || copied ? 1 : 0.5)
        }
        .buttonStyle(IconButtonStyle())
        .accessibilityLabel("Copy this dictation")
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch fix {
            case .idle:
                readOnly
            case .fixing(let selection, let typed):
                fixing(selection, typed)
            case .saved(let result):
                FixSaved(result: result, appName: item.app, copy: { TextInjector.copy(item.text) }, done: { fix = .idle })
            }
        }
        .padding(.leading, 40)
        .padding(.trailing, 12)
        .padding(.bottom, 10)
        .transition(.opacity)
    }

    /// Fix a word, steps 1 and 2: tap the wrong word, then say what it should be.
    private func fixing(_ selection: FixSelection, _ typed: String) -> some View {
        let tokens = FixTokens(item.text)
        return VStack(alignment: .leading, spacing: 10) {
            StepBar(step: selection.range == nil ? 1 : 2)
            FixText(tokens: tokens, selection: selection) { i in
                var next = selection
                next.tap(i)
                fix = .fixing(next, typed: typed)
            }
            if let range = selection.range {
                let heard = tokens.heard(range)
                FixCorrection(
                    heard: heard, typed: typed,
                    everyday: tokens.looksLikeEverydayWord(range, isRealWord: AppModel.isRealWord),
                    suggestions: { model.words.suggestions(heard: heard, typed: $0) },
                    save: { word in
                        if let result = model.fixWord(in: item.id, words: range, to: word) {
                            withAnimation(.snappy(duration: 0.18)) { fix = .saved(result) }
                        }
                    },
                    cancel: { fix = .idle })
            } else {
                Text("Tap the word Murmur got wrong. Tap a neighbour to include it.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Button("Cancel") { fix = .idle }.buttonStyle(QuietButtonStyle())
            }
        }
    }

    /// An opened dictation as it normally looks.
    private var readOnly: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(item.text)
                .font(.system(size: 14))
                .lineSpacing(3)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text("\(String(format: "%.1f", item.audioSeconds)) s of speech · typed in \(String(format: "%.2f", Double(item.transcribeMs) / 1000)) s")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            if !item.corrections.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(Array(item.corrections.enumerated()), id: \.offset) { _, fixed in
                        HStack(spacing: 5) {
                            Text("Heard").foregroundStyle(.secondary)
                            Text(fixed.heard).padding(.horizontal, 6).background(Capsule().fill(Theme.fill))
                            Text("typed").foregroundStyle(.secondary)
                            Text(fixed.written).padding(.horizontal, 6).background(Capsule().fill(Theme.accent.opacity(0.12)))
                        }
                        .font(.system(size: 11))
                    }
                }
            }

            HStack {
                Button {
                    fix = .fixing(FixSelection(), typed: "")
                } label: {
                    Label("Fix a word", systemImage: "pencil")
                }
                .buttonStyle(QuietButtonStyle())
                Spacer()
                Button {
                    if confirmingDelete { delete() } else {
                        confirmingDelete = true
                        Task {
                            try? await Task.sleep(for: .seconds(3))
                            confirmingDelete = false
                        }
                    }
                } label: {
                    Label(confirmingDelete ? "Delete for good" : "Delete", systemImage: "trash")
                }
                .buttonStyle(QuietButtonStyle(tint: confirmingDelete ? Theme.bad : .secondary))
            }
        }
    }
}
