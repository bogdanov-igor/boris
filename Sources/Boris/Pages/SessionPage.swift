import BorisCore
import BorisData
import SwiftUI

/// One session. It may be at work, or known only from its log, or gone because Claude has deleted that log.
struct SessionPage: View {
    @Bindable var model: AppModel
    var id: String

    var body: some View {
        if let session = model.session(id) {
            SessionContent(model: model, session: session)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                Crumbs(model: model)
                    .padding(EdgeInsets(top: 12, leading: 24, bottom: 12, trailing: 24))
                Rectangle().fill(Palette.separator).frame(height: 1)
                if model.pastLoaded {
                    PageEmpty(title: L("This session is gone"), text: L("Claude has deleted its log, so there is nothing left to show."))
                } else {
                    PageEmpty(title: L("Reading Claude's logs…"), text: L("The session will appear in a moment."))
                }
            }
        }
    }
}

private struct SessionContent: View {
    @Bindable var model: AppModel
    var session: WorkSession

    private var mode: DisplayMode { model.settings.displayMode }

    /// While the session works, its agents are read more often than the rest of the world.
    private var focus: Set<String> {
        guard session.state.isActive else { return [] }
        return Set(session.root.flattened.filter { $0.kind == .workflow || $0.kind == .subagent || $0.kind == .fork }.map(\.id))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Palette.separator).frame(height: 1)
            if mode == .technical { technical } else { simple }
        }
        .onChange(of: focus, initial: true) { _, runs in model.focus(on: runs) }
        .onDisappear { model.focus(on: []) }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Crumbs(model: model, project: .some(session.projectPath), projectIsLast: false)
            HStack(spacing: 10) {
                Text(session.displayName)
                    .font(.system(size: 18, weight: .semibold, design: session.nameIsFolder ? .monospaced : .default))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(1)
                EnvironmentChip(environment: session.environment)
                if let place = session.place, place.isSeparateCopy { CopyBadge(place: place, mode: mode) }
                HStack(spacing: 6) {
                    StatusGlyph(kind: StatusGlyph.Kind(session.state), size: 14)
                    Text(WorkPhrases.outcome(session.state, mode: mode)).lineLimit(1)
                }
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(session.state.color)
                .fixedSize()
                if let duration = ProjectWords.duration(session, now: model.now) {
                    Text(duration).font(.system(size: 12).monospacedDigit()).foregroundStyle(Palette.text2).lineLimit(1).fixedSize()
                }
                Spacer(minLength: 0)
            }
            if mode == .technical {
                Text(technicalLine)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Palette.text2)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
        }
        .padding(EdgeInsets(top: 12, leading: 24, bottom: 12, trailing: 20))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var technicalLine: String {
        var parts = [session.id]
        if let model = session.root.model { parts.append(model) }
        if let branch = session.place?.branch { parts.append(L("branch %@", branch)) }
        if let cwd = session.cwd { parts.append(ProjectWords.folder(cwd)) }
        return parts.joined(separator: " · ")
    }

    // MARK: - Technical

    private var technical: some View {
        GeometryReader { frame in
            HStack(spacing: 0) {
                aside.frame(width: frame.size.width < 800 ? 300 : 380)
                Rectangle().fill(Palette.separator).frame(width: 1)
                SessionFeedView(model: model, session: session).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var agentsTitle: String {
        let nodes = session.root.flattened
        let agents = nodes.filter { $0.kind != .workflow && $0.kind != .workflowAgent }.count
        let workflows = nodes.filter { $0.kind == .workflow }.count
        switch workflows {
        case 0: return L("Agents · %lld", agents)
        case 1: return L("Agents · %lld + workflow", agents)
        default: return L("Agents · %lld + %lld workflows", agents, workflows)
        }
    }

    private func heading(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(Palette.text2)
            .padding(.leading, 6)
            .padding(.bottom, 4)
    }

    private var aside: some View {
        let failures = session.failures
        return ScrollView {
            // One flat lazy stack from top to bottom. A nested stack would lay out all of its lines at once.
            LazyVStack(alignment: .leading, spacing: 0) {
                heading(agentsTitle)
                ForEach(AgentTree.rows(root: session.root, expanded: model.expandedPhases)) { row in
                    AgentTreeLine(model: model, row: row, waitingFor: session.waitingFor)
                }
                heading(L("Failures · %lld", failures.count)).padding(.top, 14)
                SessionFailuresList(model: model, failures: failures).padding(.horizontal, 8)
                SessionTokensCard(model: model, session: session)
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: DesignMetrics.radiusLarge).fill(Palette.fill1))
                    .padding(.top, 14)
            }
            .padding(EdgeInsets(top: 12, leading: 12, bottom: 16, trailing: 12))
        }
    }

    // MARK: - Simple

    /// Only what is on its way. What went wrong is under «Failures», and what ended well is told by the feed.
    private var workflowCards: [WorkNode] {
        session.root.flattened.filter { $0.workflow?.status.isActive == true }
    }

    private var simple: some View {
        let failures = session.failures
        return HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    // A session that has ended is not doing anything «now», it is only known how it ended.
                    Text(session.state.isActive ? L("Now") : L("Outcome")).font(.system(size: 12)).foregroundStyle(Palette.text2)
                    Text(WorkPhrases.occupation(session, mode: .simple))
                        .font(.system(size: 20, weight: .semibold))
                        .lineLimit(2)
                        .truncationMode(.tail)
                    if session.workingAgents > 0 {
                        Text(WorkPhrases.agentsWorking(session.workingAgents))
                            .font(.system(size: 13))
                            .foregroundStyle(Palette.text2)
                    }
                }
                ForEach(workflowCards) { WorkflowProgressCard(node: $0) }
                SessionFeedView(model: model, session: session).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    card {
                        Text(L("Failures")).font(.system(size: 13, weight: .semibold))
                        SessionFailuresList(model: model, failures: failures)
                    }
                    card { SessionTokensCard(model: model, session: session) }
                }
            }
            .frame(width: 280)
        }
        .padding(EdgeInsets(top: 22, leading: 24, bottom: 0, trailing: 24))
    }

    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) { content() }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(RoundedRectangle(cornerRadius: DesignMetrics.radiusLarge).strokeBorder(Palette.separator))
    }
}
