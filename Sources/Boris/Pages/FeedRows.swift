import AppKit
import BorisCore
import BorisData
import SwiftUI

extension StatusGlyph.Kind {
    init(_ state: StepState) {
        switch state {
        case .running: self = .running
        case .done: self = .done
        case .failed: self = .failed
        case .unfinished: self = .unknown
        }
    }
}

extension ActivityStep {
    /// A path keeps its file name when it is cut. A command keeps its start, as its end alone says nothing.
    var targetTruncation: Text.TruncationMode {
        kind == .read || isChange ? .middle : .tail
    }
}

/// `+12 −3`, each number in its own colour, or nothing for a call with no change to count.
struct ChangeCounts: View {
    var added: Int?
    var removed: Int?
    var size: CGFloat = 11

    var body: some View {
        if (added ?? 0) > 0 || (removed ?? 0) > 0 {
            HStack(spacing: 4) {
                if let added, added > 0 { Text(verbatim: "+\(added)").foregroundStyle(Palette.done) }
                if let removed, removed > 0 { Text(verbatim: "−\(removed)").foregroundStyle(Palette.redText) }
            }
            .font(.system(size: size, design: .monospaced))
            .fixedSize()
        }
    }
}

/// Puts text on the clipboard and shows for a moment that it did. The text is made only when asked for.
struct CopyLink: View {
    var title: String
    var font: Font = .system(size: 11)
    var color: Color = Palette.text2
    var text: () async -> String?
    @State private var copied = false

    var body: some View {
        Button {
            Task {
                guard let value = await text() else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(value, forType: .string)
                copied = true
                try? await Task.sleep(for: .seconds(1.2))
                copied = false
            }
        } label: {
            Text(copied ? L("Copied") : title).font(font).foregroundStyle(copied ? Palette.done : color).lineLimit(1)
        }
        .buttonStyle(.plain)
    }
}

/// Claude's words with their bold and code marks. Line breaks stay as written.
private func inlineMarkdown(_ text: String) -> AttributedString {
    let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
    return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
}

/// What the person asked, or the task an agent was given. A long one stays folded until asked for.
struct FeedPromptCard: View {
    var title: String
    var text: String
    @State private var unfolded = false

    private static let foldedLines = 6

    private var isLong: Bool {
        text.count > 400 || text.components(separatedBy: "\n").count > Self.foldedLines
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Text(title).font(.system(size: 11).monospacedDigit()).foregroundStyle(Palette.text3).lineLimit(1)
                Spacer(minLength: 0)
                CopyLink(title: L("Copy"), text: { text })
            }
            Text(inlineMarkdown(text))
                .font(.system(size: 12.5))
                .lineSpacing(3)
                .lineLimit(unfolded ? nil : Self.foldedLines)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            if isLong {
                Button(unfolded ? L("Show less") : L("Show all of it")) { unfolded.toggle() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.text2)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: DesignMetrics.radiusLarge).fill(Palette.fill1))
        .padding(.bottom, 6)
    }
}

/// Claude's own remark between two steps, with its headings, lists and code shown as such.
struct FeedNote: View {
    var title: String
    var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 11).monospacedDigit()).foregroundStyle(Palette.text3).lineLimit(1)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(TextBlock.parse(text).enumerated()), id: \.offset) { _, block in
                    switch block {
                    case .heading(let line):
                        Text(inlineMarkdown(line)).font(.system(size: 12.5, weight: .semibold))
                    case .paragraph(let line):
                        Text(inlineMarkdown(line)).font(.system(size: 12.5)).lineSpacing(3)
                    case .bullet(let line):
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(verbatim: "•")
                            Text(inlineMarkdown(line))
                        }
                        .font(.system(size: 12.5))
                    case .code(let code):
                        Text(code)
                            .font(.system(size: 11.5, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(7)
                            .background(RoundedRectangle(cornerRadius: DesignMetrics.radiusMedium).fill(Palette.monoBackground))
                    }
                }
            }
            .textSelection(.enabled)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .leading) { Rectangle().fill(Palette.separator).frame(width: 2) }
        .padding(EdgeInsets(top: 6, leading: 44, bottom: 6, trailing: 0))
    }
}

/// The sign that an agent is busy between two calls.
struct FeedThinkingRow: View {
    var agent: String?

    var body: some View {
        HStack(spacing: 8) {
            StatusGlyph(kind: .silent, size: 14)
            if let agent {
                Text(agent).font(.system(size: 11)).lineLimit(1).frame(width: 100, alignment: .leading)
            }
            Text(L("Thinking…")).font(.system(size: 12))
        }
        .foregroundStyle(Palette.text2)
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity, minHeight: 26, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// How long a step took, or for how long it has been going.
struct StepTimer: View {
    var step: ActivityStep
    var waiting = false
    var size: CGFloat = 11

    var body: some View {
        if waiting {
            Text(L("waiting for you")).font(.system(size: size)).foregroundStyle(Palette.waiting).lineLimit(1).fixedSize()
        } else if step.state == .running, let started = step.startedAt {
            TimelineView(.periodic(from: .now, by: 1)) { moment in
                Text(L("running %@", WorkPhrases.clock(moment.date.timeIntervalSince(started))))
                    .font(.system(size: size).monospacedDigit())
                    .foregroundStyle(Palette.running)
                    .lineLimit(1)
                    .fixedSize()
            }
        } else if step.state == .running {
            Text(L("running")).font(.system(size: size)).foregroundStyle(Palette.running).lineLimit(1).fixedSize()
        } else if let duration = step.duration {
            Text(WorkPhrases.stepDuration(duration))
                .font(.system(size: size).monospacedDigit())
                .foregroundStyle(Palette.text2)
                .lineLimit(1)
                .fixedSize()
        }
    }
}

/// A step of the technical feed: one line that opens into what it did.
struct FeedStepRow: View {
    var entry: FeedEntry
    var step: ActivityStep
    var agent: String
    var cwd: String?
    var now: Date
    var isOpen: Bool
    var waiting = false
    var store: FeedStore
    var toggle: () -> Void

    /// An MCP tool's long name says the same as its short one, which the details still show in full.
    private var title: Text {
        let target = WorkPhrases.target(step, cwd: cwd) ?? ""
        if step.tool.hasPrefix("mcp__") { return Text(target.isEmpty ? step.tool : target).fontWeight(.semibold) }
        return Text(step.tool).fontWeight(.semibold) + Text(verbatim: " " + target)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: toggle) {
                HStack(spacing: 8) {
                    StatusGlyph(kind: waiting ? .waiting : StatusGlyph.Kind(step.state), size: 14)
                    Text(agent)
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.text2)
                        .lineLimit(1)
                        .frame(width: 100, alignment: .leading)
                    title
                        .font(.system(size: 11.5, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(step.targetTruncation)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    ChangeCounts(added: step.added, removed: step.removed)
                    StepTimer(step: step, waiting: waiting)
                    if let at = step.startedAt {
                        Text(WorkPhrases.time(at, now: now, seconds: false))
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundStyle(Palette.text3)
                            .lineLimit(1)
                            .fixedSize()
                    }
                    Image(systemName: isOpen ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(Palette.text2)
                        .frame(width: 10)
                }
                .padding(.horizontal, 6)
                .frame(minHeight: 28)
                .background(RoundedRectangle(cornerRadius: DesignMetrics.radiusMedium).fill(isOpen ? Palette.fill1 : .clear))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(.isButton)
            .accessibilityValue(isOpen ? L("Expanded") : L("Collapsed"))
            if isOpen {
                StepDetails(entry: entry, step: step, cwd: cwd, store: store, technical: true)
                    .padding(EdgeInsets(top: 2, leading: 28, bottom: 6, trailing: 0))
            }
        }
    }
}

/// What a step did: the change, the command and its output, and in the technical view the tool, time and tokens.
struct StepDetails: View {
    var entry: FeedEntry
    var step: ActivityStep
    var cwd: String?
    var store: FeedStore
    var technical: Bool

    private var showsOutput: Bool { step.kind != .read && !(step.output ?? "").isEmpty }

    var body: some View {
        let hasDiff = step.isChange && !step.diff().isEmpty
        VStack(alignment: .leading, spacing: 4) {
            if hasDiff { DiffBlock(entry: entry, step: step, cwd: cwd, store: store) }
            // A change that went well has nothing to add, one that failed says why here.
            if hasDiff ? step.state == .failed && showsOutput : step.input.command != nil || showsOutput {
                outputBlock
            }
            if technical { facts }
        }
    }

    private var outputBlock: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let command = step.input.command {
                Text(step.kind == .shell ? "$ \(command)" : command)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if showsOutput { Rectangle().fill(Palette.separator).frame(height: 1) }
            }
            if showsOutput, let output = step.output {
                Text(ResultFormat.pretty(output))
                    .foregroundStyle(step.state == .failed ? Palette.redText : Palette.text2)
                    .padding(EdgeInsets(top: 4, leading: 8, bottom: 6, trailing: 8))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .font(.system(size: 11.5, design: .monospaced))
        .lineSpacing(2)
        .textSelection(.enabled)
        .background(RoundedRectangle(cornerRadius: DesignMetrics.radiusMedium).fill(Palette.window))
        .overlay(RoundedRectangle(cornerRadius: DesignMetrics.radiusMedium).strokeBorder(Palette.separator))
    }

    /// Tool, parameters, time and tokens. Tokens belong to the whole message, which may have made several calls.
    private var facts: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(factsLine)
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(Palette.text2)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                CopyLink(title: L("Copy event")) { await store.full(entry)?.raw }
            }
            ForEach(step.input.parameters, id: \.name) { parameter in
                (Text(verbatim: "\(parameter.name): ").foregroundStyle(Palette.text3) + Text(verbatim: parameter.value).foregroundStyle(Palette.text2))
                    .font(.system(size: 11, design: .monospaced))
                    .lineLimit(3)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
        }
        .padding(.horizontal, 2)
        .padding(.top, 2)
    }

    private var factsLine: String {
        var parts = [step.tool]
        if let target = step.input.target, step.isChange || step.kind == .read { parts.append(target) }
        if let duration = step.duration { parts.append(WorkPhrases.stepDuration(duration)) }
        if let error = WorkPhrases.stepError(step) { parts.append(L("error: %@", error)) }
        if let tokens = step.tokens {
            parts.append(L("message tokens: in %@, out %@, cache %@", WorkFormat.tokens(tokens.input), WorkFormat.tokens(tokens.output), WorkFormat.tokens(tokens.cacheRead + tokens.cacheWrite)))
        }
        return parts.joined(separator: " · ")
    }
}

/// Removed and added lines, numbered, in the colours of the design.
struct DiffRows: View {
    var lines: [DiffLines.Line]

    var body: some View {
        ForEach(lines) { line in
            HStack(alignment: .top, spacing: 0) {
                Text(line.number.map(String.init) ?? "")
                    .foregroundStyle(Palette.text3)
                    .frame(width: 36, alignment: .trailing)
                    .padding(.trailing, 6)
                Text(sign(line.kind)).fontWeight(.bold).frame(width: 14, alignment: .leading)
                Text(line.text).frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.trailing, 8)
            .foregroundStyle(color(line.kind))
            .background(background(line.kind))
        }
        .font(.system(size: 11.5, design: .monospaced))
        .lineSpacing(3)
    }

    private func sign(_ kind: DiffLines.Line.Kind) -> String {
        switch kind {
        case .removed: return "−"
        case .added: return "+"
        case .context: return ""
        }
    }

    private func color(_ kind: DiffLines.Line.Kind) -> Color {
        switch kind {
        case .removed: return Palette.redText
        case .added: return Palette.done
        case .context: return Palette.text2
        }
    }

    private func background(_ kind: DiffLines.Line.Kind) -> Color {
        switch kind {
        case .removed: return Palette.redSoft
        case .added: return Palette.doneSoft
        case .context: return .clear
        }
    }
}

/// Says why a written file has no counts: its lines are all shown as new, and only the log could have told otherwise.
private struct OverwriteNote: View {
    var body: some View {
        Text(L("The file was written over, and its old text is not in the log."))
            .font(.system(size: 11))
            .foregroundStyle(Palette.text2)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The start of a change inside the feed. The rest opens on request.
struct DiffBlock: View {
    var entry: FeedEntry
    var step: ActivityStep
    var cwd: String?
    var store: FeedStore

    private static let preview = 12

    var body: some View {
        let lines = step.diff()
        let shown = Array(lines.prefix(Self.preview))
        let total = max((step.added ?? 0) + (step.removed ?? 0), lines.count)
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(Palette.text3)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .frame(maxWidth: .infinity, alignment: .leading)
            Rectangle().fill(Palette.separator).frame(height: 1)
            if step.oldTextUnknown { OverwriteNote().padding(.horizontal, 8).padding(.vertical, 3) }
            DiffRows(lines: shown).textSelection(.enabled)
            Rectangle().fill(Palette.separator).frame(height: 1)
            Button {
                store.shownDiff = DiffRequest(title: title, entries: [entry])
            } label: {
                Text(total > shown.count ? Self.moreTitle(total - shown.count) : L("Show all of it"))
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.text2)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .background(Palette.window)
        .clipShape(RoundedRectangle(cornerRadius: DesignMetrics.radiusMedium))
        .overlay(RoundedRectangle(cornerRadius: DesignMetrics.radiusMedium).strokeBorder(Palette.separator))
    }

    private var title: String { step.input.target.map { WorkPhrases.path($0, cwd: cwd) } ?? "" }

    private static func moreTitle(_ count: Int) -> String {
        count == 1 ? L("%lld more line · Show all", count) : L("%lld more lines · Show all", count)
    }
}

/// Every removed and added line of a change, with the unchanged lines around them. A long change is read again from the transcript.
struct DiffSheet: View {
    var title: String
    var entries: [FeedEntry]
    var store: FeedStore
    @Environment(\.dismiss) private var dismiss
    /// The lines of a long change, once it has been read again from its transcript.
    @State private var whole: [String: [DiffLines.Line]] = [:]

    private var namesFiles: Bool { Set(entries.compactMap { $0.step?.input.target }).count > 1 }

    private func lines(_ step: ActivityStep) -> [DiffLines.Line] {
        whole[step.id] ?? step.diff(context: true)
    }

    /// Comparing two long texts takes a while, and the window has to stay alive meanwhile.
    private func wholeLines(_ step: ActivityStep, _ found: ActivityReader.FullStep) async -> [DiffLines.Line] {
        var copy = step
        copy.input = found.input
        copy.hunks = found.hunks
        let changed = copy
        return await Task.detached(priority: .userInitiated) { changed.diff(context: true) }.value
    }

    var body: some View {
        let steps = entries.compactMap(\.step)
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text(title)
                    .font(.system(size: 12.5, weight: .semibold, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                ChangeCounts(
                    added: steps.reduce(0) { $0 + ($1.added ?? 0) },
                    removed: steps.reduce(0) { $0 + ($1.removed ?? 0) },
                    size: 11.5
                )
                Spacer(minLength: 8)
                Button(L("Close")) { dismiss() }
                    .buttonStyle(PlainActionStyle())
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 14)
            .frame(height: 44)
            Rectangle().fill(Palette.separator).frame(height: 1)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(steps) { step in
                        LazyVStack(alignment: .leading, spacing: 0) {
                            if namesFiles, let target = step.input.target {
                                Text(target)
                                    .font(.system(size: 10.5, design: .monospaced))
                                    .foregroundStyle(Palette.text3)
                                    .padding(.horizontal, 14)
                                    .padding(.bottom, 3)
                            }
                            if step.oldTextUnknown { OverwriteNote().padding(.horizontal, 14).padding(.bottom, 3) }
                            DiffRows(lines: lines(step))
                        }
                        .textSelection(.enabled)
                    }
                }
                .padding(.vertical, 10)
            }
        }
        .background(Palette.window)
        .foregroundStyle(Palette.text1)
        .frame(minWidth: 680, idealWidth: 760, minHeight: 460, idealHeight: 560)
        .task {
            for entry in entries where entry.step?.isCut == true {
                if let step = entry.step, let found = await store.full(entry) { whole[step.id] = await wholeLines(step, found) }
            }
        }
    }
}
