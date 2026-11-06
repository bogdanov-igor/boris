import BorisCore
import BorisData
import SwiftUI

/// Projects, then one project, then one session. The way down and the way back are all here.
struct ProjectsPage: View {
    @Bindable var model: AppModel

    var body: some View {
        Group {
            if !model.world.claudeFolderFound {
                FolderMissing(model: model).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                switch model.projectsRoute {
                case .list: ProjectList(model: model)
                case .project(let path): ProjectPage(model: model, path: path)
                case .session(let id): SessionPage(model: model, id: id)
                }
            }
        }
        .onAppear { model.refreshPastSessions() }
    }
}

private struct ProjectList: View {
    @Bindable var model: AppModel
    @State private var width: CGFloat = 1000

    private var mode: DisplayMode { model.settings.displayMode }
    private var filter: ProjectFilter { model.projectFilter }

    /// On a narrow window the list of environments gives way, since each session names its own further down.
    private var showsEnvironments: Bool { width >= 760 }
    /// The Usage page has it in every breakdown, and the state of a project must stay readable here.
    private var showsEstimate: Bool { width >= 700 }
    private var showsToday: Bool {
        if case .today = filter.period { return false }
        return true
    }

    private var columns: [ColumnsLayout.Column] {
        var columns: [ColumnsLayout.Column] = [.flex(1.1), .flex(1.7)]
        if showsEnvironments { columns.append(.flex(1.2)) }
        columns += [.fixed(52)]
        if showsToday { columns.append(.fixed(70)) }
        columns.append(.fixed(70))
        if showsEstimate { columns.append(.fixed(72)) }
        columns += [.fixed(46), .fixed(74)]
        return columns
    }

    private var periodTitle: String {
        switch filter.period {
        case .today: return L("Today")
        case .week: return L("7 days")
        case .month: return L("30 days")
        case .dates: return L("Period")
        }
    }

    var body: some View {
        let sessions = model.allSessions
        let projects = ProjectBook.summaries(sessions: sessions, tokens: model.usage.records, filter: filter, now: model.now)
        VStack(spacing: 0) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    title(count: projects.count)
                    Spacer(minLength: 0)
                    ProjectFilterBar(model: model, environments: ProjectBook.environments(of: sessions))
                }
                VStack(alignment: .leading, spacing: 8) {
                    title(count: projects.count)
                    ProjectFilterBar(model: model, environments: ProjectBook.environments(of: sessions))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(EdgeInsets(top: 14, leading: 24, bottom: 12, trailing: 24))
            Rectangle().fill(Palette.separator).frame(height: 1)
            if projects.isEmpty {
                empty(hasSessions: !sessions.isEmpty)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        table(projects)
                        Text(L("Tokens: today and for the period. Chat and Cowork without a project folder go under «No project»."))
                            .font(.system(size: 11))
                            .foregroundStyle(Palette.text3)
                            .padding(.leading, 4)
                    }
                    .padding(EdgeInsets(top: 16, leading: 24, bottom: 20, trailing: 24))
                }
            }
        }
    }

    private func title(count: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(L("Projects")).font(.system(size: 18, weight: .semibold))
            if count > 0 {
                Text(L("%lld · those waiting for you or with failures first", count))
                    .font(.system(size: 12.5))
                    .foregroundStyle(Palette.text2)
                    .lineLimit(1)
            }
        }
    }

    @ViewBuilder private func empty(hasSessions: Bool) -> some View {
        if !model.pastLoaded, !hasSessions {
            PageEmpty(title: L("Reading Claude's logs…"), text: L("Projects will appear in a moment."))
        } else if hasSessions {
            PageEmpty(title: L("Nothing in this period"), text: L("Try a longer period or another environment."))
        } else {
            PageEmpty(title: L("No projects yet"), text: L("Projects appear here when Claude starts working in a folder."))
        }
    }

    private func table(_ projects: [ProjectSummary]) -> some View {
        VStack(spacing: 0) {
            ColumnsLayout(columns: columns) {
                TableHeadCell(L("Project"))
                TableHeadCell(L("Now"))
                if showsEnvironments { TableHeadCell(L("Environments")) }
                TableHeadCell(L("Sessions"), trailing: true)
                if showsToday { TableHeadCell(L("Today"), trailing: true) }
                TableHeadCell(periodTitle, trailing: true)
                if showsEstimate { TableHeadCell(L("Estimate"), trailing: true) }
                TableHeadCell(L("Failures"), trailing: true)
                TableHeadCell(L("Last"), trailing: true)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Palette.fill1)
            LazyVStack(spacing: 0) {
                ForEach(projects) { row($0) }
            }
            total(projects)
        }
        .clipShape(RoundedRectangle(cornerRadius: DesignMetrics.radiusLarge))
        .overlay(RoundedRectangle(cornerRadius: DesignMetrics.radiusLarge).strokeBorder(Palette.separator))
        .onGeometryChange(for: CGFloat.self, of: { $0.size.width }, action: { width = $0 })
    }

    private func row(_ project: ProjectSummary) -> some View {
        RowButton(help: project.path.map(ProjectWords.folder)) {
            model.openProject(project.path)
        } label: {
            ColumnsLayout(columns: columns) {
                TableCell(text: ProjectWords.name(project.path), font: .system(size: 12.5, weight: .semibold, design: project.path == nil ? .default : .monospaced))
                ProjectStateLabel(project: project, mode: mode, now: model.now).frame(maxWidth: .infinity, alignment: .leading)
                if showsEnvironments {
                    TableCell(text: project.environments.map { WorkPhrases.environment($0) }.joined(separator: ", "), font: .system(size: 11.5), color: Palette.text2)
                }
                TableCell(text: "\(project.sessions.count)", trailing: true)
                if showsToday { TableCell(text: WorkFormat.tokens(project.today.total), trailing: true) }
                TableCell(text: WorkFormat.tokens(project.inPeriod.total), trailing: true, font: .system(size: 12.5, weight: .semibold).monospacedDigit())
                if showsEstimate { TableCell(text: UsageFormat.estimateCell(project.estimate), trailing: true, font: .system(size: 12).monospacedDigit(), color: Palette.text2) }
                TableCell(text: "\(project.failures)", trailing: true, font: .system(size: 12.5, weight: project.failures > 0 ? .semibold : .regular).monospacedDigit(), color: project.failures > 0 ? Palette.redText : Palette.text2)
                TableCell(text: ProjectWords.lastSeen(project.lastActivity, isActive: !project.active.isEmpty, now: model.now), trailing: true, font: .system(size: 11.5).monospacedDigit(), color: Palette.text2)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(minHeight: 48)
            .background(project.lead?.state == .waiting ? Palette.waitingSoft : .clear)
            .overlay(alignment: .top) { Rectangle().fill(Palette.separator).frame(height: 1) }
        }
    }

    private func total(_ projects: [ProjectSummary]) -> some View {
        ColumnsLayout(columns: columns) {
            TableCell(text: L("Total"), font: .system(size: 12, weight: .semibold))
            Color.clear
            if showsEnvironments { Color.clear }
            TableCell(text: "\(projects.reduce(0) { $0 + $1.sessions.count })", trailing: true, font: .system(size: 12, weight: .semibold).monospacedDigit())
            if showsToday {
                TableCell(text: WorkFormat.tokens(projects.reduce(0) { $0 + $1.today.total }), trailing: true, font: .system(size: 12, weight: .semibold).monospacedDigit())
            }
            TableCell(text: WorkFormat.tokens(projects.reduce(0) { $0 + $1.inPeriod.total }), trailing: true, font: .system(size: 12, weight: .semibold).monospacedDigit())
            if showsEstimate {
                TableCell(text: UsageFormat.estimateCell(projects.reduce(into: SpendEstimate()) { $0.add($1.estimate) }), trailing: true, font: .system(size: 12, weight: .semibold).monospacedDigit())
            }
            let failures = projects.reduce(0) { $0 + $1.failures }
            TableCell(text: "\(failures)", trailing: true, font: .system(size: 12, weight: .semibold).monospacedDigit(), color: failures > 0 ? Palette.redText : Palette.text2)
            Color.clear
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 32)
        .background(Palette.fill1)
        .overlay(alignment: .top) { Rectangle().fill(Palette.separator).frame(height: 1) }
    }
}

/// How a project is doing: what its most important session says.
struct ProjectStateLabel: View {
    var project: ProjectSummary
    var mode: DisplayMode
    var now: Date
    var size: CGFloat = 14
    var font = Font.system(size: 12.5)

    private var text: String {
        guard let lead = project.lead else { return L("No sessions in this period") }
        switch lead.state {
        case .waiting:
            guard let last = lead.lastActivity else { return WorkPhrases.state(.waiting, mode: mode) }
            return "\(WorkPhrases.state(.waiting, mode: mode)) · \(WorkFormat.duration(max(now.timeIntervalSince(last), 0)))"
        case .running:
            return "\(WorkPhrases.state(.running, mode: mode)) · \(WorkPhrases.agents(max(lead.workingAgents, 1)))"
        case .silent, .finished, .failed, .stopped, .interrupted:
            return WorkPhrases.outcome(lead.state, mode: mode)
        case .unreachable:
            if case .remote(let host) = lead.environment { return L("No connection to %@", host) }
            return WorkPhrases.state(.unreachable, mode: mode)
        }
    }

    var body: some View {
        let state = project.lead?.state
        HStack(spacing: 6) {
            StatusGlyph(kind: state.map(StatusGlyph.Kind.init) ?? .idle, size: size)
            Text(text)
                .font(font)
                .fontWeight(state == .waiting ? .semibold : .regular)
                .foregroundStyle(state?.color ?? Palette.text2)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }
}
