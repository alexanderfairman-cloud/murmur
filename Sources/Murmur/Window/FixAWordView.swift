import MurmurCore
import SwiftUI

/// Where "Fix a word" is for one opened dictation.
enum FixState: Equatable {
    case idle
    /// Choosing the word (nothing chosen yet) or correcting it. `typed` is what the box starts with.
    case fixing(FixSelection, typed: String)
    case saved(FixResult)
}

/// Pick, Correct, Saved: shows where you are in the three steps.
struct StepBar: View {
    let step: Int

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(["Pick", "Correct", "Saved"].enumerated()), id: \.offset) { index, label in
                Text("\(index + 1) \(label)")
                    .font(.system(size: 11))
                    .foregroundStyle(index < step ? Color.primary : Color.secondary)
                if index < 2 {
                    Capsule().fill(index < step - 1 ? Theme.accent : Theme.hairline).frame(width: 26, height: 3)
                }
            }
        }
    }
}

/// The dictation as tappable words. Tap the wrong one; tap a neighbour to include it.
struct FixText: View {
    let tokens: FixTokens
    let selection: FixSelection
    let tap: (Int) -> Void

    /// Indices grouped by line, so line breaks in the dictation stay line breaks.
    private var lines: [[Int]] {
        var result: [[Int]] = []
        for (i, token) in tokens.tokens.enumerated() {
            if token.lineBreaksBefore > 0 || result.isEmpty { result.append([i]) } else { result[result.count - 1].append(i) }
        }
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                FlowLayout(spacing: 2) {
                    ForEach(line, id: \.self) { i in
                        TokenButton(
                            text: tokens.tokens[i].text,
                            chosen: selection.range?.contains(i) == true,
                            neighbor: selection.isNeighbor(i)
                        ) { tap(i) }
                    }
                }
                .padding(.top, (tokens.tokens[line[0]].lineBreaksBefore >= 2) ? 8 : 0)
            }
        }
    }
}

private struct TokenButton: View {
    let text: String
    let chosen: Bool
    let neighbor: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(text)
                .font(.system(size: 14))
                .foregroundStyle(chosen ? Color.white : Color.primary)
                .padding(.horizontal, 2)
                .padding(.vertical, 1)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(chosen ? Theme.accent : (hovering ? Theme.accent.opacity(0.14) : .clear)))
                .overlay(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .strokeBorder(Theme.accent.opacity(neighbor ? 0.6 : 0), style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(text)
    }
}

/// Step 2: say what the word should be.
struct FixCorrection: View {
    let heard: String
    let suggestions: (String) -> [String]
    let everyday: Bool
    let save: (String) -> Void
    let cancel: () -> Void

    @State private var typed: String
    @State private var missing = false
    @FocusState private var focused: Bool

    init(
        heard: String, typed: String, everyday: Bool, suggestions: @escaping (String) -> [String],
        save: @escaping (String) -> Void, cancel: @escaping () -> Void
    ) {
        self.heard = heard
        self.everyday = everyday
        self.suggestions = suggestions
        self.save = save
        self.cancel = cancel
        _typed = State(initialValue: typed)
    }

    private func submit() {
        let word = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        if word.isEmpty { missing = true } else { save(word) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Heard \u{201C}\(heard)\u{201D}, should be")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize()
                TextField("The right word", text: $typed)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .focused($focused)
                    .onSubmit(submit)
                    .onExitCommand(perform: cancel)
                    .padding(.horizontal, 8)
                    .frame(height: 28)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.fill))
                    .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Theme.accent.opacity(focused ? 0.8 : 0), lineWidth: 1))
            }

            let chips = suggestions(typed)
            if !chips.isEmpty {
                HStack(spacing: 6) {
                    ForEach(chips, id: \.self) { word in
                        Button(word) { typed = word }
                            .buttonStyle(.plain)
                            .font(.system(size: 11))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Theme.fill))
                    }
                }
            }

            if missing {
                Text("Type the right word first.").font(.system(size: 12)).foregroundStyle(Theme.bad)
            }

            if everyday {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(Theme.warn)
                    Text("\u{201C}\(heard)\u{201D} is an everyday word. Murmur would change every \u{201C}\(heard)\u{201D} you say to what you type here, in every dictation.")
                        .font(.system(size: 12))
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.warn.opacity(0.12)))
            } else {
                Text("From now on \u{201C}\(heard.lowercased())\u{201D} becomes what you type here. It is added to that word in Words.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                Button(everyday ? "Save anyway" : "Save", action: submit).buttonStyle(PrimaryButtonStyle())
                Button("Cancel", action: cancel).buttonStyle(QuietButtonStyle())
            }
            .padding(.top, 2)
        }
        .onAppear { focused = true }
        .onChange(of: typed) { _, _ in missing = false }
    }
}

/// Step 3: the corrected text, what was saved, and a way to copy the fix.
struct FixSaved: View {
    let result: FixResult
    let appName: String?
    let copy: () -> Void
    let done: () -> Void
    @State private var copied = false

    private var message: String {
        var parts = ["Saved."]
        if result.createdWord { parts.append("Added \u{201C}\(result.written)\u{201D} to Words.") }
        parts.append(result.ruleAdded
            ? "From now on \u{201C}\(result.heard)\u{201D} becomes \u{201C}\(result.written)\u{201D}."
            : "Murmur already spells \u{201C}\(result.written)\u{201D} your way.")
        parts.append("It cannot change what is already typed\(appName.map { " in \($0)" } ?? "").")
        return parts.joined(separator: " ")
    }

    private var corrected: AttributedString {
        var text = AttributedString(result.newText)
        let s = result.newText
        if let start = s.index(s.startIndex, offsetBy: result.range.lowerBound, limitedBy: s.endIndex),
           let end = s.index(start, offsetBy: result.range.count, limitedBy: s.endIndex),
           let range = Range(start..<end, in: text) {
            text[range].backgroundColor = Theme.accent.opacity(0.2)
        }
        return text
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            StepBar(step: 3)
            Text(corrected)
                .font(.system(size: 14))
                .lineSpacing(3)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "checkmark").foregroundStyle(Theme.ok)
                Text(message).font(.system(size: 12))
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.ok.opacity(0.12)))
            HStack {
                Button {
                    copy()
                    copied = true
                    Task {
                        try? await Task.sleep(for: .seconds(1))
                        copied = false
                    }
                } label: {
                    Label(copied ? "Copied" : "Copy fixed text", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(QuietButtonStyle())
                Spacer()
                Button("Done", action: done).buttonStyle(QuietButtonStyle())
            }
        }
    }
}
