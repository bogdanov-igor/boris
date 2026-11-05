import BorisCore
import BorisData
import SwiftUI

/// The agents of a session as a flat list with indents, ready for a lazy stack. Only the lines on screen cost anything, so a run of hundreds of agents scrolls like a short one.
struct AgentTreeLine: View {
    @Bindable var model: AppModel
    var row: AgentTreeRow
    var waitingFor: WaitingReason?

    private static let indent: CGFloat = 18

    var body: some View {
        content
            .padding(.leading, row.edge == .none ? CGFloat(row.depth) * Self.indent : CGFloat(row.cardDepth) * Self.indent)
    }

    @ViewBuilder private var content: some View {
        switch row.content {
        case .agent(let node):
            let inner = row.edge == .none ? 0 : CGFloat(row.depth - row.cardDepth) * Self.indent
            carded(AgentLine(model: model, node: node, waitingFor: waitingFor).padding(.leading, inner))
        case .workflow(let node):
            carded(WorkflowLine(model: model, node: node))
        case .phase(let phase, let workflowId):
            carded(PhaseLine(model: model, phase: phase, workflowId: workflowId))
        }
    }

    @ViewBuilder private func carded<Content: View>(_ view: Content) -> some View {
        if row.edge == .none {
            view
        } else {
            view
                .padding(.horizontal, 4)
                .padding(.top, row.edge == .top || row.edge == .whole ? 8 : 0)
                .padding(.bottom, row.edge == .bottom || row.edge == .whole ? 6 : 0)
                .overlay(CardEdge(edge: row.edge).stroke(Palette.separator))
                .padding(.top, row.edge == .top || row.edge == .whole ? 6 : 0)
        }
    }
}

/// The part of a card's border that one of its lines draws. A card made of lines stays lazy, where a card around them would not.
private struct CardEdge: Shape {
    var edge: AgentTreeRow.CardEdge

    private static let radius: CGFloat = 8

    func path(in rect: CGRect) -> Path {
        let r = Self.radius
        let (left, right, top, bottom) = (rect.minX + 0.5, rect.maxX - 0.5, rect.minY + 0.5, rect.maxY - 0.5)
        var path = Path()
        if edge == .top || edge == .whole {
            path.move(to: CGPoint(x: left, y: edge == .whole ? bottom - r : rect.maxY))
            path.addLine(to: CGPoint(x: left, y: top + r))
            path.addQuadCurve(to: CGPoint(x: left + r, y: top), control: CGPoint(x: left, y: top))
            path.addLine(to: CGPoint(x: right - r, y: top))
            path.addQuadCurve(to: CGPoint(x: right, y: top + r), control: CGPoint(x: right, y: top))
            path.addLine(to: CGPoint(x: right, y: edge == .whole ? bottom - r : rect.maxY))
        }
        if edge == .middle {
            path.move(to: CGPoint(x: left, y: rect.minY))
            path.addLine(to: CGPoint(x: left, y: rect.maxY))
            path.move(to: CGPoint(x: right, y: rect.minY))
            path.addLine(to: CGPoint(x: right, y: rect.maxY))
        }
        if edge == .bottom || edge == .whole {
            path.move(to: CGPoint(x: left, y: edge == .whole ? bottom - r : rect.minY))
            path.addLine(to: CGPoint(x: left, y: bottom - r))
            path.addQuadCurve(to: CGPoint(x: left + r, y: bottom), control: CGPoint(x: left, y: bottom))
            path.addLine(to: CGPoint(x: right - r, y: bottom))
            path.addQuadCurve(to: CGPoint(x: right, y: bottom - r), control: CGPoint(x: right, y: bottom))
            path.addLine(to: CGPoint(x: right, y: edge == .whole ? bottom - r : rect.minY))
        }
        return path
    }
}

/// One agent: its state, name, tokens and what it is doing. Pressing it limits the feed to this agent.
private struct AgentLine: View {
    @Bindable var model: AppModel
    var node: WorkNode
    var waitingFor: WaitingReason?
    @State private var hovering = false

    private var mode: DisplayMode { model.settings.displayMode }
    private var selected: Bool { model.feedAgent == node.id }
    private var tokens: Int? {
        node.contextTokens ?? model.spendIndex.agents[node.id]?.total ?? node.tokens?.total
    }
    private var activity: String {
        // Only the main agent asks the person, and the session knows what for.
        if node.kind == .main, node.state == .waiting { return WorkPhrases.waiting(waitingFor, mode: mode) }
        return WorkPhrases.agentActivity(node, mode: mode)
    }

    /// What only a person with a reason looks for.
    private var details: String {
        var parts = [node.id]
        if let model = node.model { parts.append(model) }
        if node.attempts > 1 { parts.append(L("attempt %lld", node.attempts)) }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        Button {
            model.feedAgent = selected ? nil : node.id
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                StatusGlyph(kind: StatusGlyph.Kind(node.state), size: 14)
                    .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(WorkPhrases.agentName(node))
                            .font(.system(size: 12.5, weight: node.kind == .main ? .semibold : .medium))
                            .lineLimit(1)
                            .truncationMode(.tail)
                        if let place = node.place, place.isSeparateCopy { CopyBadge(place: place, mode: mode) }
                        Spacer(minLength: 4)
                        if let tokens {
                            Text(WorkFormat.tokens(tokens))
                                .font(.system(size: 11).monospacedDigit())
                                .foregroundStyle(Palette.text2)
                                .lineLimit(1)
                                .fixedSize()
                        }
                    }
                    Text(activity)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(node.state == .failed ? Palette.redText : Palette.text2)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if selected {
                        Text(details)
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(Palette.text3)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: DesignMetrics.radiusMedium).fill(selected ? Palette.fill2 : hovering ? Palette.fill1 : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// The head of a workflow's card: its name, how many agents and tokens, its ribbon and its honest status.
private struct WorkflowLine: View {
    @Bindable var model: AppModel
    var node: WorkNode

    private var mode: DisplayMode { model.settings.displayMode }

    private var spent: Int? {
        node.tokens?.total ?? model.spendIndex.runs[node.id]?.total ?? node.workflow?.totalTokens
    }

    private var statusLine: String {
        guard let details = node.workflow else { return "" }
        var parts = [details.stoppedByClaude ? L("Stopped by Claude") : WorkPhrases.workflow(details.status, mode: mode)]
        if details.status == .completedWithErrors { parts.append(L("failed %lld", details.failed)) }
        if node.attempts > 1 { parts.append(L("attempt %lld", node.attempts)) }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        if let details = node.workflow {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    StatusGlyph(kind: StatusGlyph.Kind(details.status), size: 14)
                    Text(WorkPhrases.workflowName(node.title, mode: mode))
                        .font(.system(size: 12.5, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if let place = node.place, place.isSeparateCopy { CopyBadge(place: place, mode: mode) }
                    Spacer(minLength: 4)
                    Text(([WorkPhrases.agents(details.total)] + (spent.map { [WorkFormat.tokens($0)] } ?? [])).joined(separator: " · "))
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(Palette.text2)
                        .lineLimit(1)
                        .fixedSize()
                }
                VStack(alignment: .leading, spacing: 4) {
                    let phases = node.phases
                    if !phases.isEmpty { WorkflowRibbon(phases: phases) }
                    Text(statusLine)
                        .font(.system(size: 11))
                        .foregroundStyle(details.status.color)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if let error = details.errorFirstLine {
                        Text(error)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Palette.redText)
                            .lineLimit(2)
                            .truncationMode(.tail)
                    }
                }
                .padding(.leading, 22)
            }
            .padding(.horizontal, 4)
            .padding(.bottom, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .help(details.description ?? "")
        }
    }
}

/// A phase folded into one line with its count. Pressing it opens its agents.
private struct PhaseLine: View {
    @Bindable var model: AppModel
    var phase: WorkflowPhase
    var workflowId: String
    @State private var hovering = false

    private var key: String { AgentTree.phaseKey(workflow: workflowId, phase: phase.title) }
    private var open: Bool { model.expandedPhases.contains(key) }

    var body: some View {
        let summary = PhaseWords.summary(phase)
        Button {
            if open { model.expandedPhases.remove(key) } else { model.expandedPhases.insert(key) }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: open ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(phase.isAhead ? Palette.text3 : Palette.text2)
                    .frame(width: 10)
                Text(phase.title ?? L("no phase"))
                    .font(.system(size: 12, weight: phase.isCurrent ? .semibold : .regular))
                    .foregroundStyle(phase.title == nil ? Palette.text2 : Palette.text1)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                Text(summary.text)
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(summary.color)
                    .lineLimit(1)
                    .fixedSize()
            }
            .padding(.leading, 22)
            .padding(.trailing, 4)
            .frame(minHeight: 24)
            .background(RoundedRectangle(cornerRadius: 5).fill(hovering ? Palette.fill1 : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(phase.isAhead)
        .onHover { hovering = $0 }
        .accessibilityValue(open ? L("Expanded") : L("Folded"))
    }
}

/// What has gone wrong in a session. In the simple mode each one says what to do about it.
struct SessionFailuresList: View {
    @Bindable var model: AppModel
    var failures: [WorkFailure]

    private var mode: DisplayMode { model.settings.displayMode }

    var body: some View {
        if failures.isEmpty {
            Text(mode == .simple ? L("Nothing broke.") : L("No failures in this session."))
                .font(.system(size: 12))
                .foregroundStyle(Palette.text2)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(failures) { failure in
                    HStack(alignment: .top, spacing: 8) {
                        StatusGlyph(kind: StatusGlyph.Kind(failure), size: 14)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(WorkPhrases.failureName(failure, mode: mode)).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.tail)
                            Text(WorkPhrases.failure(failure, mode: mode))
                                .font(.system(size: 12))
                                .foregroundStyle(Palette.redText)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
    }
}

/// What a session has spent and how full the main agent's context is.
struct SessionTokensCard: View {
    @Bindable var model: AppModel
    var session: WorkSession

    private var mode: DisplayMode { model.settings.displayMode }
    private var usage: TokenUsage? { model.spendIndex.sessions[session.id] }

    private func part(_ title: String, _ value: Int) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).foregroundStyle(Palette.text3).lineLimit(1).minimumScaleFactor(0.8)
            Text(WorkFormat.tokens(value)).monospacedDigit().lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if mode == .simple {
                Text(L("Tokens")).font(.system(size: 13, weight: .semibold))
                Text(usage.map { WorkFormat.tokens($0.total) } ?? L("No data yet"))
                    .font(.system(size: usage == nil ? 12.5 : 20, weight: usage == nil ? .regular : .semibold).monospacedDigit())
                    .foregroundStyle(usage == nil ? Palette.text2 : Palette.text1)
            } else {
                HStack {
                    Text(L("Session tokens")).foregroundStyle(Palette.text2)
                    Spacer(minLength: 4)
                    Text(usage.map { WorkFormat.tokens($0.total) } ?? L("No data yet")).fontWeight(.semibold).monospacedDigit()
                }
                .font(.system(size: 11.5))
                if let usage {
                    HStack(alignment: .top, spacing: 6) {
                        part(L("Input"), usage.input)
                        part(L("Output"), usage.output)
                        part(L("Cache, read"), usage.cacheRead)
                        part(L("Cache, write"), usage.cacheWrite)
                    }
                    .font(.system(size: 11))
                }
                if let context = session.root.contextTokens {
                    HStack {
                        Text(L("Main agent's context")).foregroundStyle(Palette.text3)
                        Spacer(minLength: 4)
                        Text(WorkFormat.tokens(context)).monospacedDigit()
                    }
                    .font(.system(size: 11))
                }
            }
        }
    }
}
