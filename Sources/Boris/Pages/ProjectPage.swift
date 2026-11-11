import BorisCore
import BorisData
import SwiftUI

/// One project: what goes on in it now and what went on before, within a period and an environment.
struct ProjectPage: View {
    @Bindable var model: AppModel
    var path: String?
    @State private var width: CGFloat = 1000

    private var mode: DisplayMode { model.settings.displayMode }

    /// On a narrow window the number of agents gives its room to the name of the session.
    private var showsAgents: Bool { width >= 720 }
    /// The Usage page has it too, and without the room the name of the session would be gone.
    private var showsEstimate: Bool { width >= 760 }

    private var pastColumns: [ColumnsLayout.Column] {
        var columns: [ColumnsLayout.Column] = [.fixed(96), .flex(1), .fixed(84), .fixed(76)]
        if showsAgents { columns.append(.fixed(46)) }
        columns.append(.fixed(62))
        if showsEstimate { columns.append(.fixed(66)) }
        return columns + [.fixed(146)]
    }

    var body: some View {
        let all = model.allSessions
        let project = SpeedLog.measure(.projectSums, items: { _ in all.count }) { ProjectBook.summary(path: path, sessions: all, tokens: model.usage.records, filter: model.projectFilter, now: model.now) }
        VStack(spacing: 0) {
            header(project)
            Rectangle().fill(Palette.separator).frame(height: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 10) {
                        ProjectFilterBar(model: model, environments: ProjectBook.environments(of: all.filter { $0.projectPath == path }), countsEnvironments: true)
                        Spacer(minLength: 0)
                        Text(rangeText)
                            .font(.system(size: 11.5))
                            .foregroundStyle(Palette.text3)
                            .lineLimit(1)
                    }
                    stats(project)
                    if !project.active.isEmpty { going(project) }
                    past(project)
                }
                .padding(EdgeInsets(top: 14, leading: 24, bottom: 20, trailing: 24))
            }
        }
    }

    private var rangeText: String {
        let days = model.projectFilter.period.days(now: model.now)
        let first = WorkFormat.day(days.lowerBound)
        let isToday = Calendar.current.isDate(days.upperBound, inSameDayAs: model.now)
        if Calendar.current.isDate(days.lowerBound, inSameDayAs: days.upperBound) {
            return isToday ? L("Today") : first
        }
        return "\(first) — \(isToday ? L("today") : WorkFormat.day(days.upperBound))"
    }

    private func header(_ project: ProjectSummary) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Crumbs(model: model, project: .some(path))
            HStack(spacing: 10) {
                Text(ProjectWords.name(path))
                    .font(.system(size: 18, weight: .semibold, design: path == nil ? .default : .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if project.lead != nil {
                    ProjectStateLabel(project: project, mode: mode, now: model.now).fixedSize()
                }
                Spacer(minLength: 0)
                if let lead = project.lead { OpenSessionButton(model: model, session: lead) }
            }
            if mode == .technical, let path {
                Text(([ProjectWords.folder(path)] + (project.lead?.place?.branch.map { [L("branch %@", $0)] } ?? [])).joined(separator: " · "))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Palette.text2)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(EdgeInsets(top: 12, leading: 24, bottom: 12, trailing: 24))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func stats(_ project: ProjectSummary) -> some View {
        ColumnsLayout(columns: [.flex(1), .flex(1), .flex(1), .flex(1), .flex(2.6)], spacing: 10) {
            stat(L("Sessions"), "\(project.sessions.count)", color: Palette.text1)
            stat(L("Tokens"), WorkFormat.tokens(project.inPeriod.total), color: Palette.text1)
            stat(L("Estimate"), UsageFormat.estimateCell(project.estimate), color: Palette.text1)
            stat(L("Failures"), "\(project.failures)", color: project.failures > 0 ? Palette.redText : Palette.text1)
            TokensByDay(byDay: project.byDay, period: model.projectFilter.period, now: model.now)
        }
    }

    private func stat(_ title: String, _ value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 11)).foregroundStyle(Palette.text2).lineLimit(1)
            Text(value).font(.system(size: 17, weight: .semibold).monospacedDigit()).foregroundStyle(color).lineLimit(1).minimumScaleFactor(0.7)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: DesignMetrics.radiusLarge).fill(Palette.fill1))
    }

    private func going(_ project: ProjectSummary) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L("Going on now · %lld", project.active.count))
                .font(.system(size: 13, weight: .semibold))
                .padding(.leading, 4)
            ForEach(project.active) { LiveSessionCard(model: model, session: $0) }
        }
    }

    private func past(_ project: ProjectSummary) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L("Past sessions · %lld", project.past.count))
                .font(.system(size: 13, weight: .semibold))
                .padding(.leading, 4)
            if project.past.isEmpty {
                Text(model.pastLoaded ? L("No past sessions in this period. Boris shows what Claude still keeps in its logs.") : L("Reading Claude's logs…"))
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.text2)
                    .padding(.leading, 4)
            } else {
                VStack(spacing: 0) {
                    ColumnsLayout(columns: pastColumns) {
                        TableHeadCell(L("Started"))
                        TableHeadCell(L("Session"))
                        TableHeadCell(L("Environment"))
                        TableHeadCell(L("Lasted"), trailing: true)
                        if showsAgents { TableHeadCell(L("Agents"), trailing: true) }
                        TableHeadCell(L("Tokens"), trailing: true)
                        if showsEstimate { TableHeadCell(L("Estimate"), trailing: true) }
                        TableHeadCell(L("Outcome"))
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Palette.fill1)
                    LazyVStack(spacing: 0) {
                        ForEach(project.past) { pastRow($0) }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: DesignMetrics.radiusLarge))
                .overlay(RoundedRectangle(cornerRadius: DesignMetrics.radiusLarge).strokeBorder(Palette.separator))
                .onGeometryChange(for: CGFloat.self, of: { $0.size.width }, action: { width = $0 })
            }
        }
    }

    private func pastRow(_ session: WorkSession) -> some View {
        RowButton(help: session.title) {
            model.openSession(session.id)
        } label: {
            ColumnsLayout(columns: pastColumns) {
                TableCell(text: (session.startedAt ?? session.lastActivity).map { WorkFormat.moment($0, now: model.now) } ?? "", font: .system(size: 12).monospacedDigit())
                HStack(spacing: 6) {
                    Text(session.nameIsFolder ? "" : session.displayName)
                        .font(.system(size: 12))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if let place = session.place, place.isSeparateCopy { CopyBadge(place: place, mode: mode) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                TableCell(text: WorkPhrases.environment(session.environment), font: .system(size: 12), color: Palette.text2)
                TableCell(text: ProjectWords.duration(session, now: model.now) ?? "", trailing: true, font: .system(size: 12).monospacedDigit(), color: Palette.text2)
                if showsAgents { TableCell(text: "\(session.agentCount)", trailing: true, font: .system(size: 12).monospacedDigit(), color: Palette.text2) }
                TableCell(text: spent(session), trailing: true, font: .system(size: 12, weight: .semibold).monospacedDigit())
                if showsEstimate { TableCell(text: UsageFormat.estimateCell(model.usage.book?.estimate(session: session.id)), trailing: true, font: .system(size: 11.5).monospacedDigit(), color: Palette.text2) }
                HStack(spacing: 6) {
                    StatusGlyph(kind: StatusGlyph.Kind(session.state), size: 14)
                    Text(WorkPhrases.outcome(session.state, mode: mode))
                        .font(.system(size: 12))
                        .foregroundStyle(session.state.color)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 28)
            .overlay(alignment: .top) { Rectangle().fill(Palette.separator).frame(height: 1) }
        }
    }

    private func spent(_ session: WorkSession) -> String {
        model.usage.book?.spent(session: session.id).map { WorkFormat.tokens($0.total) } ?? "–"
    }
}

/// A session at work: when it started and where, who it waits for and what has failed in it. It never looks like nothing is going on.
struct LiveSessionCard: View {
    @Bindable var model: AppModel
    var session: WorkSession

    private var mode: DisplayMode { model.settings.displayMode }
    private var waiting: Bool { session.state == .waiting }

    private var place: String {
        var parts: [String] = []
        parts.append(WorkPhrases.environment(session.environment))
        if let duration = ProjectWords.duration(session, now: model.now) { parts.append(L("going for %@", duration)) }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 14) {
                StatusGlyph(kind: StatusGlyph.Kind(session.state))
                HStack(spacing: 0) {
                    Text((session.startedAt).map { WorkFormat.moment($0, now: model.now) } ?? session.displayName).fontWeight(.semibold)
                    Text(verbatim: " · \(place)").foregroundStyle(Palette.text2)
                }
                .font(.system(size: 12.5))
                .lineLimit(1)
                .truncationMode(.tail)
                if let place = session.place, place.isSeparateCopy { CopyBadge(place: place, mode: mode) }
                Spacer(minLength: 0)
                Text(WorkPhrases.agents(max(session.workingAgents, 1))).font(.system(size: 12.5).monospacedDigit()).foregroundStyle(Palette.text2).lineLimit(1)
                Text(model.usage.book?.spent(session: session.id).map { WorkFormat.tokens($0.total) } ?? "–").font(.system(size: 12.5, weight: .semibold).monospacedDigit()).lineLimit(1)
                Text(UsageFormat.estimateCell(model.usage.book?.estimate(session: session.id))).font(.system(size: 12).monospacedDigit()).foregroundStyle(Palette.text2).lineLimit(1)
                Button(L("Open session")) { model.openSession(session.id) }.buttonStyle(PlainActionStyle())
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(WorkPhrases.line(session, mode: mode))
                    .foregroundStyle(waiting ? Palette.waiting : Palette.text2)
                    .fontWeight(waiting ? .medium : .regular)
                ForEach(session.failures.prefix(3)) { failure in
                    Text(verbatim: "\(WorkPhrases.failureName(failure, mode: mode)): \(WorkPhrases.failure(failure, mode: mode))")
                        .foregroundStyle(Palette.redText)
                }
            }
            .font(.system(size: 12))
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.leading, 30)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: DesignMetrics.radiusLarge).fill(waiting ? Palette.waitingSoft : .clear))
        .overlay(RoundedRectangle(cornerRadius: DesignMetrics.radiusLarge).strokeBorder(waiting ? Palette.waiting : Palette.separator))
    }
}

/// Spend by day: thin bars from one baseline, each with its value in a tooltip. One series, so the title names it and no legend is needed.
struct TokensByDay: View {
    var byDay: [String: Int]
    var period: WorkPeriod
    var now: Date

    /// The days of the period, and at least a week: one lonely bar says nothing about how a project is going.
    private var days: [Date] {
        let calendar = Calendar.current
        let range = period.days(now: now)
        var last = calendar.startOfDay(for: range.upperBound)
        let first = calendar.startOfDay(for: range.lowerBound)
        var result: [Date] = []
        while result.count < 30, last >= first || result.count < 7 {
            result.insert(last, at: 0)
            guard let earlier = calendar.date(byAdding: .day, value: -1, to: last) else { break }
            last = earlier
        }
        return result
    }

    var body: some View {
        let days = days
        let values = days.map { byDay[ProjectBook.dayKey($0)] ?? 0 }
        let largest = max(values.max() ?? 0, 1)
        let labelled = days.count <= 10
        VStack(alignment: .leading, spacing: 4) {
            Text(L("Tokens by day")).font(.system(size: 11)).foregroundStyle(Palette.text2)
            HStack(alignment: .bottom, spacing: labelled ? 6 : 2) {
                ForEach(Array(zip(days, values)), id: \.0) { day, value in
                    VStack(spacing: 2) {
                        if labelled {
                            Text(value > 0 ? WorkFormat.tokens(value) : "").font(.system(size: 9.5).monospacedDigit()).foregroundStyle(Palette.text2).lineLimit(1).minimumScaleFactor(0.7)
                        }
                        UnevenRoundedRectangle(topLeadingRadius: 2, topTrailingRadius: 2)
                            .fill(Palette.meter)
                            .frame(maxWidth: 22)
                            .frame(height: value > 0 ? max(2, 34 * CGFloat(value) / CGFloat(largest)) : 1)
                            .opacity(value > 0 ? 1 : 0.35)
                        if labelled {
                            Text(Calendar.current.isDate(day, inSameDayAs: now) ? L("Tod.") : WorkFormat.shortDay(day)).font(.system(size: 9.5)).foregroundStyle(Palette.text3).lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .help("\(WorkFormat.day(day)) · \(WorkFormat.tokens(value))")
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(WorkFormat.day(day)), \(WorkFormat.tokens(value))")
                }
            }
            .frame(maxHeight: .infinity, alignment: .bottom)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(minHeight: 84)
        .background(RoundedRectangle(cornerRadius: DesignMetrics.radiusLarge).fill(Palette.fill1))
    }
}
