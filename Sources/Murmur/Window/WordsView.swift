import MurmurCore
import SwiftUI

/// Words Murmur should spell your way, edited where they are shown.
struct WordsView: View {
    @ObservedObject var model: AppModel
    @State private var query = ""
    @State private var selected: Set<String> = []
    @FocusState private var fieldFocused: Bool

    private var trimmed: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canAdd: Bool { !trimmed.isEmpty && !model.words.contains(trimmed) }
    private var matches: [DictionaryEntry] { model.words.matching(query) }

    var body: some View {
        ZStack(alignment: .bottom) {
            VStack(spacing: 8) {
                addField
                if model.dictionaryDamaged { damagedNotice }
                if model.words.entries.isEmpty {
                    emptyState
                } else if matches.isEmpty {
                    Text("No words match. Press Return to add it.")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    list
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 38)

            if !selected.isEmpty { bulkBar.padding(.bottom, 16).transition(.move(edge: .bottom).combined(with: .opacity)) }
        }
        .animation(.snappy(duration: 0.18), value: selected.isEmpty)
    }

    private var addField: some View {
        HStack(spacing: 8) {
            Image(systemName: "plus").foregroundStyle(.secondary).font(.system(size: 12))
            TextField("Type a word to add or find", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($fieldFocused)
                .onSubmit(add)
            if canAdd {
                Button("Add word", action: add).buttonStyle(PrimaryButtonStyle())
            } else if !query.isEmpty {
                Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear")
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 34)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.fill))
    }

    private func add() {
        if model.addWord(trimmed) { query = "" }
    }

    private var damagedNotice: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle").foregroundStyle(Theme.warn)
            Text("dictionary.json could not be read, so Murmur is using the last good list. Saving a change here replaces the file.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.warn.opacity(0.1)))
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(matches) { entry in
                    WordRow(
                        model: model, entry: entry,
                        isSelected: selected.contains(entry.word),
                        select: {
                            if selected.contains(entry.word) { selected.remove(entry.word) } else { selected.insert(entry.word) }
                        })
                }
            }
            .padding(.bottom, selected.isEmpty ? 16 : 70)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "character.book.closed").font(.system(size: 26)).foregroundStyle(.tertiary)
            Text("Teach Murmur a name").font(.system(size: 14, weight: .medium)).padding(.top, 4)
            Text("Add a word it gets wrong, like a person, a product, or a company. It will spell it your way from then on.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
            Button("Add a word") { fieldFocused = true }
                .buttonStyle(PrimaryButtonStyle())
                .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.bottom, 60)
    }

    private var bulkBar: some View {
        HStack(spacing: 14) {
            Text("\(selected.count) selected").font(.system(size: 12))
            Button("Delete") {
                model.deleteWords(selected)
                selected = []
            }
            .buttonStyle(.plain)
            .font(.system(size: 12, weight: .semibold))
            Button { selected = [] } label: { Image(systemName: "xmark") }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear selection")
        }
        .foregroundStyle(Color(nsColor: .windowBackgroundColor))
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(Capsule().fill(Color(nsColor: .labelColor)))
    }
}

private struct WordRow: View {
    @ObservedObject var model: AppModel
    let entry: DictionaryEntry
    let isSelected: Bool
    let select: () -> Void

    @State private var hovering = false
    @State private var adding = false
    @State private var newSpelling = ""
    @FocusState private var spellingFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Button(action: select) {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 14))
                        .foregroundStyle(isSelected ? Theme.accent : Color.secondary.opacity(hovering ? 0.9 : 0.5))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Select \(entry.word)")

                Text(entry.word).font(.system(size: 14, weight: .medium))
                Spacer()
                Text("\(model.wordUsage[entry.word] ?? 0)")
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .help("Times this word fixed a dictation")
                Button { model.deleteWords([entry.word]) } label: {
                    Image(systemName: "trash").foregroundStyle(Color.secondary.opacity(hovering ? 1 : 0.5))
                }
                .buttonStyle(IconButtonStyle())
                .accessibilityLabel("Delete \(entry.word)")
            }

            FlowLayout(spacing: 6) {
                ForEach(entry.heardAs, id: \.self) { spelling in
                    HStack(spacing: 4) {
                        Text(spelling)
                        Button { model.removeHeardAs(spelling, from: entry.word) } label: {
                            Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Remove \(spelling)")
                    }
                    .font(.system(size: 11))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Theme.fill))
                }
                if adding {
                    TextField("what it heard", text: $newSpelling)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11))
                        .frame(width: 110)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(Capsule().strokeBorder(Theme.accent, lineWidth: 1))
                        .focused($spellingFocused)
                        .onSubmit(commit)
                        .onExitCommand { adding = false; newSpelling = "" }
                } else {
                    Button {
                        adding = true
                        spellingFocused = true
                    } label: {
                        Text("+ heard as").font(.system(size: 11)).foregroundStyle(.secondary)
                            .padding(.horizontal, 8).padding(.vertical, 2)
                            .background(Capsule().strokeBorder(Color.secondary.opacity(0.4), style: StrokeStyle(lineWidth: 0.8, dash: [3, 2])))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Add a wrong spelling for \(entry.word)")
                }
            }
            .padding(.leading, 24)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(hovering || isSelected ? Theme.hover : .clear))
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairline).frame(height: 0.5).padding(.horizontal, 8) }
        .onHover { hovering = $0 }
    }

    private func commit() {
        model.addHeardAs(newSpelling, to: entry.word)
        newSpelling = ""
        adding = false
    }
}
