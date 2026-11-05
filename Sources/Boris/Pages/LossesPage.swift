import BorisCore
import BorisData
import SwiftUI

struct LossesPage: View {
    @Bindable var model: AppModel

    private var mode: DisplayMode { model.settings.displayMode }

    var body: some View {
        Group {
            if let book = model.losses.book {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        LossSummaryLayout {
                            ReasonsCard(book: book, mode: mode)
                            KindsCard(book: book)
                            VStack(spacing: 10) {
                                LostTokensCard(tokens: book.lostTokens)
                                LossSpendCard(book: book)
                            }
                            .frame(maxHeight: .infinity, alignment: .top)
                        }
                        failures(book)
                    }
                    .padding(EdgeInsets(top: 16, leading: 24, bottom: 24, trailing: 24))
                }
            } else {
                LossesReading(progress: model.losses.progress)
            }
        }
        .task { await model.losses.follow(model) }
        .onChange(of: model.losses.period) {
            Task { await model.losses.periodChanged(model) }
        }
    }

    private func failures(_ book: LossBook) -> some View {
        let store = model.losses
        let rows = book.entries(kind: store.kind, project: store.project, environment: store.environment)
        return VStack(alignment: .leading, spacing: 8) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) {
                    chips
                    Spacer(minLength: 6)
                    menus(book)
                }
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) { chips }
                    HStack(spacing: 6) { menus(book) }
                }
            }
            LazyVStack(spacing: 0) {
                if rows.isEmpty {
                    Text(book.entries.isEmpty ? L("No failures in this period") : L("Nothing matches these filters"))
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.text2)
                        .frame(maxWidth: .infinity, minHeight: 68)
                }
                ForEach(rows) { entry in
                    LossRow(entry: entry, mode: mode, now: model.now, isLast: entry.id == rows.last?.id) {
                        open(entry)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: DesignMetrics.radiusLarge))
            .overlay(RoundedRectangle(cornerRadius: DesignMetrics.radiusLarge).strokeBorder(Palette.separator))
            Text(L("Clicking a row takes you to the failure in the session's feed."))
                .font(.system(size: 11.5))
                .foregroundStyle(Palette.text3)
        }
    }

    @ViewBuilder private var chips: some View {
        Text(L("Failures"))
            .font(.system(size: 13, weight: .semibold))
            .padding(.trailing, 6)
        let store = model.losses
        LossChip(title: L("All"), selected: store.kind == nil) { store.kind = nil }
        ForEach(LossKind.allCases) { item in
            LossChip(title: LossPhrases.kind(item), selected: store.kind == item) { store.kind = item }
        }
    }

    @ViewBuilder private func menus(_ book: LossBook) -> some View {
        @Bindable var store = model.losses
        LossMenu(label: L("Project"), allTitle: L("All projects"), options: book.projects.map { ($0, $0) }, selection: $store.project)
        LossMenu(label: L("Environment"), allTitle: L("All environments"), options: book.environments.map { ($0, WorkPhrases.environment($0)) }, selection: $store.environment)
    }

    /// Leads to the session, with its feed on the agent that failed when that is known.
    private func open(_ entry: LossEntry) {
        model.openSession(entry.sessionId, agent: entry.agentId)
    }
}

/// The choice of a period, in the page's header.
struct LossPeriodBar: View {
    @Bindable var store: LossStore

    var body: some View {
        ChoiceBar(options: LossPeriod.allCases.map { ($0, Self.title($0)) }, selection: $store.period, label: L("Period"))
    }

    private static func title(_ period: LossPeriod) -> String {
        switch period {
        case .week: return L("7 days")
        case .month: return L("30 days")
        case .all: return L("All time")
        }
    }
}

/// Three columns while there is room for them. In a narrow window the third goes under the other two.
private struct LossSummaryLayout: Layout {
    private static let weights: [CGFloat] = [1.25, 1, 0.9]
    private static let threeColumnsFrom: CGFloat = 780
    private let spacing: CGFloat = 14

    private func widths(for width: CGFloat) -> (first: CGFloat, second: CGFloat, third: CGFloat) {
        if width >= Self.threeColumnsFrom {
            let share = (width - 2 * spacing) / Self.weights.reduce(0, +)
            return (share * Self.weights[0], share * Self.weights[1], share * Self.weights[2])
        }
        let share = (width - spacing) / (Self.weights[0] + Self.weights[1])
        return (share * Self.weights[0], share * Self.weights[1], width)
    }

    private func height(of view: LayoutSubview, width: CGFloat) -> CGFloat {
        view.sizeThatFits(ProposedViewSize(width: width, height: nil)).height
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 942
        guard subviews.count == 3 else { return CGSize(width: width, height: 0) }
        let columns = widths(for: width)
        let top = max(height(of: subviews[0], width: columns.first), height(of: subviews[1], width: columns.second))
        let third = height(of: subviews[2], width: columns.third)
        return CGSize(width: width, height: width >= Self.threeColumnsFrom ? max(top, third) : top + spacing + third)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 3 else { return }
        let columns = widths(for: bounds.width)
        let wide = bounds.width >= Self.threeColumnsFrom
        let top = max(height(of: subviews[0], width: columns.first), height(of: subviews[1], width: columns.second))
        let rowHeight = wide ? bounds.height : top
        subviews[0].place(at: bounds.origin, proposal: ProposedViewSize(width: columns.first, height: rowHeight))
        subviews[1].place(at: CGPoint(x: bounds.minX + columns.first + spacing, y: bounds.minY), proposal: ProposedViewSize(width: columns.second, height: rowHeight))
        let third = wide
            ? CGPoint(x: bounds.minX + columns.first + columns.second + 2 * spacing, y: bounds.minY)
            : CGPoint(x: bounds.minX, y: bounds.minY + top + spacing)
        subviews[2].place(at: third, proposal: ProposedViewSize(width: columns.third, height: wide ? bounds.height : nil))
    }
}

private struct LossCard<Content: View>: View {
    var spacing: CGFloat = 6
    var verticalPadding: CGFloat = 12
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: spacing, content: content)
            .padding(.horizontal, 14)
            .padding(.vertical, verticalPadding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .overlay(RoundedRectangle(cornerRadius: DesignMetrics.radiusLarge).strokeBorder(Palette.separator))
    }
}

private struct ReasonsCard: View {
    var book: LossBook
    var mode: DisplayMode

    var body: some View {
        LossCard(spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(L("Failed agents by reason"))
                    .font(.system(size: 12.5, weight: .semibold))
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(verbatim: "\(book.crashed)")
                    .font(.system(size: 20, weight: .semibold).monospacedDigit())
            }
            if book.reasons.isEmpty {
                Text(L("No agent failed in this period"))
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.text2)
            } else {
                let largest = book.reasons.first?.count ?? 1
                Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 8) {
                    ForEach(book.reasons) { row in
                        GridRow {
                            Text(LossPhrases.reason(row.reason, mode: mode))
                                .foregroundStyle(Palette.text2)
                                .lineLimit(1)
                            LossBar(fraction: Double(row.count) / Double(max(largest, 1)), color: row.reason == .limit ? Palette.limit : Palette.meter)
                            Text(verbatim: "\(row.count)")
                                .fontWeight(.semibold)
                                .monospacedDigit()
                                .gridColumnAlignment(.trailing)
                        }
                    }
                }
                .font(.system(size: 12))
            }
        }
    }
}

private struct LossBar: View {
    var fraction: Double
    var color: Color

    var body: some View {
        GeometryReader { frame in
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.meterTrack)
                // Even the smallest share stays visible next to a huge one.
                Capsule().fill(color).frame(width: max(frame.size.width * fraction, 2))
            }
        }
        .frame(height: 6)
    }
}

private struct KindsCard: View {
    var book: LossBook

    var body: some View {
        LossCard {
            Text(L("Failures by type")).font(.system(size: 12.5, weight: .semibold))
            ForEach(LossKind.allCases) { kind in
                HStack(spacing: 8) {
                    Text(LossPhrases.kindInFull(kind))
                        .foregroundStyle(Palette.text2)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(verbatim: "\(book.kinds[kind] ?? 0)")
                        .fontWeight(.semibold)
                        .monospacedDigit()
                }
                .font(.system(size: 12))
                .frame(minHeight: 20)
            }
        }
    }
}

private struct LostTokensCard: View {
    var tokens: Int?

    var body: some View {
        LossCard(spacing: 2) {
            Text(L("Lost tokens"))
                .font(.system(size: 12))
                .foregroundStyle(Palette.text2)
            Text(tokens.map(LossPhrases.estimate) ?? L("no data"))
                .font(.system(size: 20, weight: .semibold).monospacedDigit())
                .lineLimit(1)
            Text(L("estimate: tokens of failed agents"))
                .font(.system(size: 11))
                .foregroundStyle(Palette.text3)
        }
        .fixedSize(horizontal: false, vertical: true)
        .help(L("What the failed agents really spent. It is only an estimate of the loss, as part of their work may have been of use."))
    }
}

private struct LossSpendCard: View {
    var book: LossBook

    private static let skillsShown = 5

    var body: some View {
        let top = book.skills.prefix(Self.skillsShown)
        let rest = book.skills.dropFirst(Self.skillsShown)
        let others = rest.reduce(0) { $0 + $1.calls }
        LossCard(verticalPadding: 10) {
            Grid(alignment: .leading, horizontalSpacing: 4, verticalSpacing: 3) {
                GridRow {
                    // The labels take all the room there is, so the numbers line up on the right.
                    Text(L("Skill calls")).fontWeight(.semibold).frame(maxWidth: .infinity, alignment: .leading)
                    count(book.skillCalls).fontWeight(.semibold)
                }
                ForEach(top) { skill in
                    GridRow {
                        Text(skill.name ?? L("Unnamed skill"))
                            .font(.system(size: 11.5, design: .monospaced))
                            .foregroundStyle(Palette.text2)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .padding(.leading, 10)
                        count(skill.calls).foregroundStyle(Palette.text2)
                    }
                }
                if others > 0 {
                    GridRow {
                        Text(L("others")).foregroundStyle(Palette.text2).padding(.leading, 10)
                        count(others).foregroundStyle(Palette.text2)
                    }
                    .help(LossPhrases.skillCounts(rest))
                }
                estimate(L("Tokens on skills"), book.skillTokens)
                GridRow {
                    Text(L("Internet")).fontWeight(.semibold).padding(.top, 4)
                    Color.clear.frame(width: 0, height: 0)
                }
                GridRow {
                    Text(L("Searches")).foregroundStyle(Palette.text2).padding(.leading, 10)
                    count(book.searches).foregroundStyle(Palette.text2)
                }
                GridRow {
                    Text(L("Page loads")).foregroundStyle(Palette.text2).padding(.leading, 10)
                    count(book.fetches).foregroundStyle(Palette.text2)
                }
                estimate(L("Tokens on the internet"), book.webTokens)
            }
            .font(.system(size: 12))
        }
    }

    private func count(_ value: Int) -> Text {
        Text(verbatim: "\(value)").monospacedDigit()
    }

    private func estimate(_ title: String, _ tokens: Int) -> some View {
        GridRow {
            Text(title)
                .foregroundStyle(Palette.text2)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            (Text(LossPhrases.estimate(tokens)).monospacedDigit() + Text(verbatim: " ") + Text(L("estimate")).font(.system(size: 10.5)).foregroundStyle(Palette.text3))
                .lineLimit(1)
                .fixedSize()
        }
        .help(L("An estimate from the size of the text that came back, about four characters per token. The numbers of calls are exact."))
    }
}

private struct LossChip: View {
    var title: String
    var selected: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12))
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 9)
                .frame(height: 22)
                .background(Capsule().fill(selected ? Palette.fill2 : .clear))
                .overlay(Capsule().strokeBorder(Palette.buttonBorder, lineWidth: 0.5))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct LossMenu<Value: Hashable>: View {
    var label: String
    var allTitle: String
    var options: [(value: Value, title: String)]
    @Binding var selection: Value?

    private var current: String {
        options.first { $0.value == selection }?.title ?? allTitle
    }

    var body: some View {
        Menu {
            Button(allTitle) { selection = nil }
            ForEach(options, id: \.value) { option in
                Button(option.title) { selection = option.value }
            }
        } label: {
            HStack(spacing: 4) {
                Text(current)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 150)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 8, weight: .semibold))
            }
            .font(.system(size: 12))
            .foregroundStyle(Palette.text1)
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(RoundedRectangle(cornerRadius: DesignMetrics.radiusMedium).fill(Palette.button))
            .overlay(RoundedRectangle(cornerRadius: DesignMetrics.radiusMedium).strokeBorder(Palette.buttonBorder, lineWidth: 0.5))
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel(label)
    }
}

private struct LossRow: View {
    var entry: LossEntry
    var mode: DisplayMode
    var now: Date
    var isLast: Bool
    var action: () -> Void

    private var glyph: StatusGlyph.Kind {
        switch entry.kind {
        case .crash: return (entry.total ?? 0) > 1 && entry.count == entry.total ? .allFailed : .failed
        case .apiError: return entry.reason == .limit ? .limit : .failed
        case .toolError: return .failed
        case .retry: return .silent
        case .cut: return .unknown
        case .denied: return .stopped
        }
    }

    private var kindColor: Color {
        switch entry.kind {
        case .crash, .apiError, .toolError: return Palette.redText
        case .retry, .cut, .denied: return Palette.text1
        }
    }

    private var title: String {
        if let title = entry.title, !title.isEmpty { return title }
        if entry.runId != nil { return L("Workflow") }
        return entry.agentId == nil ? L("Main agent") : L("Agent")
    }

    private var detail: String {
        mode == .simple ? LossPhrases.advice(entry) : LossPhrases.detail(entry)
    }

    /// All of the row, which a narrow window cuts short, and what is too technical for it. Nothing here is the text of a prompt or a result.
    private var details: String {
        let row = "\(title) · \(detail)"
        guard mode == .technical else { return row }
        let ids = [entry.sessionId, entry.agentId].compactMap { $0?.prefix(8) }.map(String.init)
        let code = [entry.code, entry.status.map(String.init)].compactMap { $0 }
        return "\(row)\n\((ids + code).joined(separator: " · "))"
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                StatusGlyph(kind: glyph, size: 14)
                    .frame(width: 16)
                Text(LossPhrases.when(entry.at, now: now))
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(Palette.text2)
                    .lineLimit(1)
                    .frame(width: 82, alignment: .leading)
                Text(LossPhrases.kind(entry.kind))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(kindColor)
                    .lineLimit(1)
                    .frame(width: 130, alignment: .leading)
                Text(entry.project ?? "—")
                    .font(.system(size: 11.5, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(width: 110, alignment: .leading)
                LossTitleLayout {
                    Text(title)
                        .lineLimit(1)
                    Text(verbatim: " · \(detail)")
                        .foregroundStyle(Palette.text2)
                        .lineLimit(1)
                }
                .font(.system(size: 12))
                .frame(maxWidth: .infinity, alignment: .leading)
                Text(verbatim: entry.count > 1 ? "×\(entry.count)" : "")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(Palette.text3)
                    .lineLimit(1)
                    .frame(width: 46, alignment: .leading)
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Palette.text2)
                    .frame(width: 14)
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 34)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .bottom) {
            if !isLast { Rectangle().fill(Palette.separator).frame(height: 1) }
        }
        .help(details)
        .accessibilityElement(children: .combine)
    }
}

/// A name next to what happened to it. When they do not fit, what happened keeps most of the room, whatever the length of the name.
private struct LossTitleLayout: Layout {
    private static let detailShare: CGFloat = 0.6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let natural = sizes.reduce(0) { $0 + $1.width }
        return CGSize(width: min(proposal.width ?? natural, natural), height: sizes.map(\.height).max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 2 else { return }
        let title = subviews[0].sizeThatFits(.unspecified).width
        let detail = subviews[1].sizeThatFits(.unspecified).width
        let detailWidth = min(detail, max(bounds.width * Self.detailShare, bounds.width - title))
        let titleWidth = min(title, bounds.width - detailWidth)
        subviews[0].place(at: CGPoint(x: bounds.minX, y: bounds.midY), anchor: .leading, proposal: ProposedViewSize(width: titleWidth, height: nil))
        subviews[1].place(at: CGPoint(x: bounds.minX + titleWidth, y: bounds.midY), anchor: .leading, proposal: ProposedViewSize(width: detailWidth, height: nil))
    }
}

/// The first pass over the logs can take a while, and nothing can be said until it ends.
private struct LossesReading: View {
    var progress: LossIndex.Progress?

    var body: some View {
        VStack(spacing: 10) {
            if let progress {
                ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1)))
                    .frame(width: 240)
                Text(L("Reading Claude's logs: %lld of %lld", progress.done, progress.total))
            } else {
                ProgressView().controlSize(.small)
                Text(L("Reading Claude's logs…"))
            }
        }
        .font(.system(size: 12))
        .foregroundStyle(Palette.text2)
        .monospacedDigit()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
