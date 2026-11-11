import BorisCore
import BorisData
import SwiftUI

/// A row of a table: fixed columns and columns that share what is left. Every row with the same columns lines up without any row knowing the others.
struct ColumnsLayout: Layout {
    enum Column {
        case fixed(CGFloat)
        case flex(CGFloat)
    }

    var columns: [Column]
    var spacing: CGFloat = 12

    private func widths(total: CGFloat?) -> [CGFloat] {
        let fixed = columns.reduce(CGFloat(0)) { sum, column in
            if case .fixed(let width) = column { return sum + width }
            return sum
        }
        let shares = columns.reduce(CGFloat(0)) { sum, column in
            if case .flex(let share) = column { return sum + share }
            return sum
        }
        let free = total.map { max($0 - fixed - spacing * CGFloat(columns.count - 1), 0) } ?? shares * 100
        return columns.map { column in
            switch column {
            case .fixed(let width): return width
            case .flex(let share): return shares > 0 ? free * share / shares : 0
            }
        }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let widths = widths(total: proposal.width)
        var height: CGFloat = 0
        for (index, subview) in subviews.enumerated() where index < widths.count {
            height = max(height, subview.sizeThatFits(ProposedViewSize(width: widths[index], height: nil)).height)
        }
        return CGSize(width: proposal.width ?? widths.reduce(0, +) + spacing * CGFloat(max(columns.count - 1, 0)), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let widths = widths(total: bounds.width)
        var x = bounds.minX
        for (index, subview) in subviews.enumerated() where index < widths.count {
            subview.place(at: CGPoint(x: x, y: bounds.midY), anchor: .leading, proposal: ProposedViewSize(width: widths[index], height: bounds.height))
            x += widths[index] + spacing
        }
    }
}

/// A whole row that can be pressed, lit under the pointer.
struct RowButton<Label: View>: View {
    var help: String?
    var action: () -> Void
    @ViewBuilder var label: () -> Label
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            label()
                .background(hovering ? Palette.fill1 : .clear)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help ?? "")
    }
}

/// Marks work in a separate copy of the project.
struct CopyBadge: View {
    private static let longest = 22

    var place: GitPlace
    var mode: DisplayMode

    /// A long branch keeps its start and end, so the name beside it still has room. The whole of it is in the tooltip.
    /// In a tight row the badge and the name share what there is, so neither disappears.
    private var text: String {
        guard mode == .technical, let label = place.label else { return L("separate copy") }
        guard label.count > Self.longest else { return label }
        return "\(label.prefix(Self.longest / 2))…\(label.suffix(Self.longest / 2 - 1))"
    }

    private var help: String {
        guard mode == .technical else { return L("Works in a separate copy of the project") }
        let what = L("A separate copy of the project (worktree)")
        return place.label.map { "\(what): \($0)" } ?? what
    }

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "arrow.triangle.branch").font(.system(size: 9, weight: .medium))
            Text(text).font(.system(size: 10.5, design: mode == .technical ? .monospaced : .default)).lineLimit(1).truncationMode(.middle)
        }
        .foregroundStyle(Palette.text2)
        .padding(.horizontal, 5)
        .frame(height: 17)
        .background(RoundedRectangle(cornerRadius: DesignMetrics.radiusSmall).fill(Palette.fill2))
        .help(help)
        .accessibilityElement(children: .combine)
    }
}

/// Where a session runs, with a mark that can be told at a glance.
struct EnvironmentChip: View {
    var environment: WorkEnvironment?

    private var symbol: String {
        switch environment {
        case .terminal, .insideClaude: return "terminal"
        case .vsCode, .cursor: return "chevron.left.forwardslash.chevron.right"
        case .claudeDesktop, .cowork, .chat: return "sparkle"
        case .program: return "gearshape"
        case .remote: return "network"
        case nil: return "questionmark"
        }
    }

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).font(.system(size: 10, weight: .medium))
            Text(WorkPhrases.environment(environment)).font(.system(size: 11.5)).lineLimit(1)
        }
        .padding(.horizontal, 7)
        .frame(height: 22)
        .fixedSize()
        .background(RoundedRectangle(cornerRadius: 5).fill(Palette.fill1))
        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Palette.separator, lineWidth: 0.5))
        .accessibilityElement(children: .combine)
    }
}

/// `Projects › boris`, each step but the last one a way back.
struct Crumbs: View {
    @Bindable var model: AppModel
    /// The project to show after «Projects». The outer optional says whether there is a step at all.
    var project: String??
    var projectIsLast = true

    private func link(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).underline(false).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    var body: some View {
        HStack(spacing: 4) {
            link(L("Projects")) { model.backToProjects() }
            if let project {
                Text(verbatim: "›")
                let name = ProjectWords.name(project)
                if projectIsLast {
                    Text(name).lineLimit(1).truncationMode(.middle)
                } else {
                    link(name) { model.openProject(project) }.lineLimit(1).truncationMode(.middle)
                }
            }
        }
        .font(.system(size: 11.5))
        .foregroundStyle(Palette.text2)
    }
}

enum ProjectWords {
    static func name(_ path: String?) -> String {
        path.map { URL(fileURLWithPath: $0).lastPathComponent } ?? L("No project")
    }

    /// `~/dev/app`: the whole home path says nothing and takes the whole line.
    static func folder(_ path: String) -> String {
        (path as NSString).abbreviatingWithTildeInPath
    }

    /// `now` for what works, the time for today, and the day with the time before that.
    static func lastSeen(_ date: Date?, isActive: Bool, now: Date) -> String {
        if isActive { return L("now") }
        guard let date else { return "" }
        if Calendar.current.isDate(date, inSameDayAs: now) { return WorkFormat.time(date) }
        return "\(WorkFormat.shortDay(date)) \(WorkFormat.time(date))"
    }

    /// How long a session has gone on, or went on.
    static func duration(_ session: WorkSession, now: Date) -> String? {
        guard let start = session.startedAt else { return nil }
        let end = session.state.isActive ? now : session.lastActivity ?? start
        return WorkFormat.duration(max(end.timeIntervalSince(start), 0))
    }
}

extension WorkState {
    var color: Color {
        switch self {
        case .running: return Palette.running
        case .silent: return Palette.text2
        case .waiting: return Palette.waiting
        case .finished: return Palette.done
        case .failed, .interrupted: return Palette.redText
        case .stopped: return Palette.grey
        case .unreachable: return Palette.text2
        }
    }
}

/// The time and the place a list is limited to. Both pages of projects share them.
struct ProjectFilterBar: View {
    @Bindable var model: AppModel
    var environments: [WorkEnvironment]
    var countsEnvironments = false
    @State private var choosingDates = false

    private enum Choice: Hashable {
        case today, week, month, dates
    }

    private var choice: Binding<Choice> {
        Binding {
            switch model.projectFilter.period {
            case .today: return .today
            case .week: return .week
            case .month: return .month
            case .dates: return .dates
            }
        } set: { chosen in
            SpeedLog.began(.changeFilter)
            switch chosen {
            case .today: model.projectFilter.period = .today
            case .week: model.projectFilter.period = .week
            case .month: model.projectFilter.period = .month
            case .dates:
                if case .dates = model.projectFilter.period {} else {
                    model.projectFilter.period = .dates(from: Calendar.current.date(byAdding: .day, value: -29, to: model.now) ?? model.now, to: model.now)
                }
                choosingDates = true
            }
        }
    }

    private var environment: Binding<WorkEnvironment?> {
        Binding { model.projectFilter.environment } set: { model.projectFilter.environment = $0 }
    }

    /// A chosen environment stays in the list even after its last session has left the period.
    private var shownEnvironments: [WorkEnvironment] {
        if let chosen = model.projectFilter.environment, !environments.contains(chosen) { return environments + [chosen] }
        return environments
    }

    var body: some View {
        HStack(spacing: 10) {
            ChoiceBar(options: [(Choice.today, L("Today")), (.week, L("7 days")), (.month, L("30 days")), (.dates, L("Dates…"))], selection: choice, label: L("Period"))
                .popover(isPresented: $choosingDates, arrowEdge: .bottom) { ProjectDatesPicker(model: model) }
            Picker(L("Environment"), selection: environment) {
                Text(countsEnvironments && !environments.isEmpty ? L("All environments · %lld", environments.count) : L("All environments")).tag(WorkEnvironment?.none)
                ForEach(shownEnvironments, id: \.self) { place in
                    Text(WorkPhrases.environment(place)).tag(WorkEnvironment?.some(place))
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .controlSize(.small)
            .fixedSize()
        }
    }
}

/// The days a list is limited to, when none of the ready periods will do.
struct ProjectDatesPicker: View {
    @Bindable var model: AppModel

    private func date(_ pick: @escaping (Date, Date) -> Date, set: @escaping (Date, Date, Date) -> WorkPeriod) -> Binding<Date> {
        Binding {
            if case .dates(let from, let to) = model.projectFilter.period { return pick(from, to) }
            return model.now
        } set: { value in
            if case .dates(let from, let to) = model.projectFilter.period { model.projectFilter.period = set(from, to, value) }
        }
    }

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
            GridRow {
                Text(L("From")).foregroundStyle(Palette.text2)
                DatePicker("", selection: date({ from, _ in from }, set: { _, to, value in .dates(from: value, to: to) }), in: ...Date(), displayedComponents: .date).labelsHidden()
            }
            GridRow {
                Text(L("To")).foregroundStyle(Palette.text2)
                DatePicker("", selection: date({ _, to in to }, set: { from, _, value in .dates(from: from, to: value) }), in: ...Date(), displayedComponents: .date).labelsHidden()
            }
        }
        .font(.system(size: 12))
        .padding(12)
    }
}

/// A heading with a bottom line, as the tables on these pages have.
struct TableHeadCell: View {
    var title: String
    var trailing = false

    init(_ title: String, trailing: Bool = false) {
        self.title = title
        self.trailing = trailing
    }

    var body: some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Palette.text2)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: trailing ? .trailing : .leading)
    }
}

/// Text in a table cell that keeps to one line and to its column.
struct TableCell: View {
    var text: String
    var trailing = false
    var font = Font.system(size: 12.5).monospacedDigit()
    var color = Palette.text1

    var body: some View {
        Text(text)
            .font(font)
            .foregroundStyle(color)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: trailing ? .trailing : .leading)
    }
}

/// Nothing to show, and why.
struct PageEmpty: View {
    var title: String
    var text: String

    var body: some View {
        VStack(spacing: 6) {
            Text(title).font(.system(size: 15, weight: .semibold))
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(Palette.text2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
