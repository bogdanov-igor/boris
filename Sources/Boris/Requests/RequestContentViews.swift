import BorisCore
import SwiftUI

/// The frame around any content of a card.
private struct ContentFrame<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content() }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: DesignMetrics.radiusMedium).fill(Palette.window))
            .clipShape(RoundedRectangle(cornerRadius: DesignMetrics.radiusMedium))
            .overlay(RoundedRectangle(cornerRadius: DesignMetrics.radiusMedium).strokeBorder(Palette.separator))
    }
}

private struct MoreButton: View {
    var title: String
    @Binding var expanded: Bool

    var body: some View {
        Button {
            expanded.toggle()
        } label: {
            Text(expanded ? L("Collapse") : title)
                .font(.system(size: 11.5))
                .foregroundStyle(Palette.waiting)
                .padding(.horizontal, 9)
                .frame(maxWidth: .infinity, minHeight: 22, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(expanded ? L("Expanded") : L("Collapsed"))
        .overlay(alignment: .top) { Rectangle().fill(Palette.separator).frame(height: 1) }
    }
}

/// Laying out one text costs more with every line added: 30 KB holds the whole app for seconds, and 250 KB for minutes.
/// So what is longer than this is laid out a line at a time, and only where it can be seen.
enum RequestLines {
    static let limit = 4 * 1024

    static func split(_ text: String) -> [String] {
        text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
    }
}

/// All of a command or other text, as "Show all" opens it.
struct RequestWholeText: View {
    var text: String

    private var font: Font { .system(size: 12, design: .monospaced) }

    var body: some View {
        if text.utf8.count > RequestLines.limit {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(RequestLines.split(text).enumerated()), id: \.offset) { _, line in
                        Text(line.isEmpty ? " " : line).font(font).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .textSelection(.enabled)
                .padding(.horizontal, 9)
                .padding(.vertical, 7)
            }
            .frame(height: 320)
        } else {
            ScrollView {
                Text(text)
                    .font(font)
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 7)
            }
            .frame(maxHeight: 320)
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// A command or other text, folded to two lines until asked. The folded lines are the start of it, so nothing is implied about the rest.
struct RequestTextBox: View {
    var text: String
    @State private var expanded = false
    @State private var fullHeight: CGFloat = 0
    @State private var foldedHeight: CGFloat = 0

    /// Measuring a long text is wasted work: it does not fit in two lines anyway.
    private var obviouslyLong: Bool { text.utf8.count > 2000 }
    private var overflows: Bool { obviouslyLong || fullHeight > foldedHeight + 1 }

    private var folded: some View {
        Text(text)
            .font(.system(size: 12, design: .monospaced))
            .lineSpacing(3)
            .lineLimit(2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { foldedHeight = $0 }
            .background {
                if !obviouslyLong {
                    Text(text)
                        .font(.system(size: 12, design: .monospaced))
                        .lineSpacing(3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .hidden()
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { fullHeight = $0 }
                }
            }
    }

    var body: some View {
        ContentFrame {
            if expanded {
                RequestWholeText(text: text)
            } else {
                folded
                    .padding(.horizontal, 9)
                    .padding(.vertical, 7)
            }
            if overflows {
                MoreButton(title: L("Show all"), expanded: $expanded)
            }
        }
    }
}

/// The lines a file edit removes and adds, with the file on top.
struct RequestDiffBox: View {
    var path: String
    var lines: [RequestDiffLine]
    @State private var expanded = false

    private static let foldedLines = 4
    /// As many unwrapped lines as fill the open box.
    private static let linesInOpenBox = 18

    private var overflows: Bool {
        // A long line is cut while folded, so it needs the same way to be read in full as a line out of sight.
        // Counted in bytes so wide letters count for more, and low enough for the narrowest card, the mini window's.
        lines.count > Self.foldedLines || lines.prefix(Self.foldedLines).contains { $0.text.utf8.count > 32 }
    }

    /// When every line is already in sight and only cut, there are no more lines to promise.
    private var moreTitle: String {
        lines.count > Self.foldedLines ? L("Show all %lld lines", lines.count) : L("Show all")
    }

    private func row(_ line: RequestDiffLine, wraps: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text(verbatim: line.added ? "+" : "−").fontWeight(.bold).frame(width: 14, alignment: .leading)
            Text(line.text.isEmpty ? " " : line.text)
                .lineLimit(wraps ? nil : 1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(size: 11.5, design: .monospaced))
        .lineSpacing(3)
        .foregroundStyle(line.added ? Palette.done : Palette.redText)
        .padding(.horizontal, 9)
        .background(line.added ? Palette.doneSoft : Palette.redSoft)
    }

    var body: some View {
        ContentFrame {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                // Wraps rather than being cut: which file this is, is part of what is being agreed to.
                Text(path).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                Text(verbatim: "+\(lines.filter(\.added).count)").foregroundStyle(Palette.done)
                Text(verbatim: "−\(lines.filter { !$0.added }.count)").foregroundStyle(Palette.redText)
            }
            .font(.system(size: 11, design: .monospaced))
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .overlay(alignment: .bottom) { Rectangle().fill(Palette.separator).frame(height: 1) }
            if expanded {
                if lines.count > Self.linesInOpenBox {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in row(line, wraps: true) }
                        }
                        .textSelection(.enabled)
                    }
                    .frame(height: 320)
                } else {
                    // A few lines take only the room they need. A box of this height stands half empty otherwise.
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in row(line, wraps: true) }
                        }
                        .textSelection(.enabled)
                    }
                    .frame(maxHeight: 320)
                    .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                ForEach(Array(lines.prefix(Self.foldedLines).enumerated()), id: \.offset) { _, line in row(line, wraps: false) }
            }
            if overflows {
                MoreButton(title: moreTitle, expanded: $expanded)
            }
        }
    }
}

/// Claude's questions. Nothing is chosen in advance: the answer has to be the person's own.
struct RequestQuestionsBox: View {
    var questions: [RequestQuestion]
    var picked: (RequestQuestion) -> Set<String>
    var toggle: (String, RequestQuestion) -> Void

    private func hint(_ question: RequestQuestion) -> String {
        question.multiple ? L("pick any") : L("pick one")
    }

    private func mark(_ question: RequestQuestion, on: Bool) -> some View {
        Image(systemName: question.multiple ? (on ? "checkmark.square.fill" : "square") : (on ? "largecircle.fill.circle" : "circle"))
            .font(.system(size: 13))
            .foregroundStyle(on ? Palette.focus : Palette.text3)
    }

    private func option(_ option: RequestQuestion.Option, of question: RequestQuestion) -> some View {
        let on = picked(question).contains(option.label)
        return Button {
            toggle(option.label, question)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                mark(question, on: on)
                VStack(alignment: .leading, spacing: 1) {
                    Text(option.label).font(.system(size: 12.5))
                    if let detail = option.detail {
                        Text(detail).font(.system(size: 11)).foregroundStyle(Palette.text2).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(minHeight: 26)
            .background(RoundedRectangle(cornerRadius: DesignMetrics.radiusMedium).fill(on ? Palette.fill2 : Palette.fill1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(questions, id: \.text) { question in
                VStack(alignment: .leading, spacing: 4) {
                    (Text(question.text).font(.system(size: 13, weight: .medium)) + Text(verbatim: "  ") + Text(hint(question)).font(.system(size: 11)).foregroundStyle(Palette.text3))
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.bottom, 2)
                    ForEach(question.options, id: \.label) { item in
                        self.option(item, of: question)
                    }
                }
            }
        }
    }
}

/// The plan, read in place. Markdown inside lines shows as emphasis, and the line structure stays as Claude wrote it.
struct RequestPlanBox: View {
    var plan: String
    var maxHeight: CGFloat

    private func rendered(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }

    var body: some View {
        ContentFrame {
            if plan.utf8.count > RequestLines.limit {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 3) {
                        ForEach(Array(RequestLines.split(plan).enumerated()), id: \.offset) { _, line in
                            Text(line.isEmpty ? AttributedString(" ") : rendered(line))
                                .font(.system(size: 12.5))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .textSelection(.enabled)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                }
                .frame(height: maxHeight)
            } else {
                ScrollView {
                    Text(rendered(plan))
                        .font(.system(size: 12.5))
                        .lineSpacing(3)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                }
                .frame(maxHeight: maxHeight)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
