import BorisCore
import BorisData
import SwiftUI

/// The queue with the chosen request next to it, and what was decided today.
struct RequestsPage: View {
    @Bindable var model: AppModel
    @State private var width: CGFloat = 989

    private var hooks: HookController { model.hooks }
    private var rows: [RequestRow] { hooks.queue.rows(now: Date()) }
    private var chosen: RequestRow? { rows.first { $0.id == hooks.selectedRow } ?? rows.first }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if rows.isEmpty {
                    nobody
                } else if width >= 760 {
                    HStack(alignment: .top, spacing: 16) {
                        queue.frame(width: 320)
                        detail.frame(maxWidth: .infinity)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 12) {
                        queue
                        detail
                    }
                }
                RequestHistory(model: model, wide: width >= 880)
            }
            .padding(EdgeInsets(top: 16, leading: 24, bottom: 20, trailing: 24))
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }

    private var nobody: some View {
        HStack(spacing: 20) {
            WalrusView(mood: model.mood, outfit: model.outfit, size: 96, style: .simple)
            VStack(alignment: .leading, spacing: 4) {
                Text(L("Nobody is waiting for an answer")).font(.system(size: 15, weight: .semibold))
                Text(L("When Claude asks for permission, asks a question or proposes a plan, the request will show up here, in the notch and in the mini window."))
                    .font(.system(size: 13))
                    .lineSpacing(4)
                    .foregroundStyle(Palette.text2)
                    .frame(maxWidth: 560, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
        .background(RoundedRectangle(cornerRadius: 10).fill(Palette.fill1))
    }

    @ViewBuilder private var detail: some View {
        switch chosen {
        case .open(let request):
            RequestCard(model: model, request: request, surface: .window, roomy: true).id(request.id)
        case .expired, .waiting:
            if let chosen { RequestNoticeCard(model: model, row: chosen) }
        case nil:
            EmptyView()
        }
    }

    private func heading(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(Palette.text2)
            .padding(.leading, 4)
            .padding(.bottom, 2)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var queue: some View {
        let open = rows.filter(\.isOpen)
        let expired = rows.filter { if case .expired = $0 { return true } else { return false } }
        let waiting = rows.filter { if case .waiting = $0 { return true } else { return false } }
        return VStack(alignment: .leading, spacing: 4) {
            if !open.isEmpty {
                heading(L("Waiting for an answer · %lld · you can answer from Boris for %@", open.count, RequestWords.waitChoice(model.settings.permissionWaitSeconds)))
                ForEach(open) { row($0) }
            }
            if !expired.isEmpty {
                heading(L("Time to answer from Boris ran out · %lld", expired.count)).padding(.top, 6)
                ForEach(expired) { row($0) }
            }
            if !waiting.isEmpty {
                heading(L("Waiting in the session · %lld", waiting.count)).padding(.top, 6)
                ForEach(waiting) { row($0) }
            }
            Text(L("The list shows only the kind of action and the file. The text of a command opens in the card."))
                .font(.system(size: 11))
                .lineSpacing(2)
                .foregroundStyle(Palette.text3)
                .padding(EdgeInsets(top: 6, leading: 4, bottom: 0, trailing: 4))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func row(_ row: RequestRow) -> some View {
        let isChosen = chosen?.id == row.id
        let session = hooks.queue.session(row.session)
        let pid = model.world.sessions.first { $0.sessionId == row.session }.flatMap { $0.isUnlisted ? nil : $0.pid }
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                hooks.selectedRow = row.id
            } label: {
                QueueRow(model: model, row: row, chosen: isChosen)
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(isChosen ? .isSelected : [])
            // Going to the session must not take the card of an open request off the screen.
            if !row.isOpen, SessionNavigator.canOpen(session, pid: pid), let session {
                Button(session.environment == .cowork ? SessionJump.title(.cowork) : L("Open %@", WorkPhrases.environment(session.environment))) { SessionNavigator.open(session, model: model) }
                    .buttonStyle(PlainActionStyle())
                    .padding(EdgeInsets(top: 0, leading: 34, bottom: 8, trailing: 10))
            }
        }
        .background(RoundedRectangle(cornerRadius: 8).fill(isChosen ? Palette.fill2 : .clear))
        .overlay {
            RoundedRectangle(cornerRadius: 8).strokeBorder(isChosen ? Palette.waiting : (row.isOpen ? .clear : Palette.separator), lineWidth: 1)
        }
    }
}

/// One request in the list. It never shows the text of a command.
private struct QueueRow: View {
    @Bindable var model: AppModel
    var row: RequestRow
    var chosen: Bool

    private var mode: DisplayMode { model.settings.displayMode }
    private var session: WorkSession? { model.hooks.queue.session(row.session) }

    private var project: String {
        switch row {
        case .open(let request): return RequestWords.project(request.project, session: session, id: row.session, mode: mode)
        case .expired(let request): return RequestWords.project(request.project, session: session, id: row.session, mode: mode)
        case .waiting(let session): return session.name(in: mode)
        }
    }

    private var isFolder: Bool {
        switch row {
        case .open(let request): return request.project != nil
        case .expired(let request): return request.project != nil
        case .waiting(let session): return session.nameIsFolder
        }
    }

    private var environment: String {
        session.map { WorkPhrases.environment($0.environment) } ?? ""
    }

    private var line: Text {
        let parts: (tool: String?, what: String, agent: String?)
        switch row {
        case .open(let request):
            let title = session?.root.flattened.first { $0.id == request.agent }?.title
            parts = (request.tool, RequestWords.what(RequestBrief(request)), RequestWords.agent(isMain: request.agent == nil, title: title, type: request.agentType, mode: mode))
        case .expired(let request):
            parts = (request.brief.tool, RequestWords.what(request.brief), environment.isEmpty ? L("you can answer in Claude") : L("you can answer in %@", environment))
        case .waiting(let session):
            parts = (nil, WorkPhrases.waiting(session.waitingFor, mode: mode), nil)
        }
        let rest = Text(verbatim: [parts.what, parts.agent].compactMap { $0 }.joined(separator: " · "))
        guard mode == .technical, let tool = parts.tool else { return rest }
        return Text(tool).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Palette.text1) + Text(verbatim: " · ") + rest
    }

    private var glyph: StatusGlyph.Kind {
        if case .expired = row { return .stopped }
        return .waiting
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            StatusGlyph(kind: glyph)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(project)
                        .font(.system(size: 13, weight: .semibold, design: isFolder ? .monospaced : .default))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(environment).font(.system(size: 11.5)).foregroundStyle(Palette.text2).lineLimit(1)
                    Spacer(minLength: 4)
                    trailing
                }
                line
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.text2)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    @ViewBuilder private var trailing: some View {
        switch row {
        case .open(let request):
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(L("%@ of %@", RequestWords.clock(request.deadline.timeIntervalSince(context.date)), RequestWords.clock(request.deadline.timeIntervalSince(request.askedAt))))
                    .font(.system(size: 11.5, weight: .semibold).monospacedDigit())
                    .foregroundStyle(chosen ? Palette.waiting : Palette.text2)
                    .lineLimit(1)
                    .fixedSize()
            }
        case .expired(let request):
            Text(L("waiting %@", WorkFormat.duration(model.now.timeIntervalSince(request.askedAt))))
                .font(.system(size: 11.5).monospacedDigit())
                .foregroundStyle(Palette.text2)
                .lineLimit(1)
                .fixedSize()
        case .waiting:
            EmptyView()
        }
    }
}

/// The subtitle and the reminder about the keys, in the page's own header.
struct RequestsHeader: View {
    @Bindable var model: AppModel

    private var rows: [RequestRow] { model.hooks.queue.rows(now: Date()) }

    private var subtitle: String {
        let open = rows.filter(\.isOpen).count
        let elsewhere = rows.count - open
        guard !rows.isEmpty else { return L("Nobody is waiting right now") }
        var parts: [String] = []
        if open > 0 { parts.append(L("%lld waiting for an answer", open)) }
        if elsewhere > 0 { parts.append(L("%lld waiting in Claude", elsewhere)) }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        Text(subtitle)
            .font(.system(size: 12.5, weight: rows.isEmpty ? .regular : .semibold))
            .foregroundStyle(rows.isEmpty ? Palette.text2 : Palette.waiting)
            .lineLimit(1)
            .allowsHitTesting(false)
        Spacer(minLength: 8)
        // Shortened as a whole phrase: cut anywhere, the reminder about Enter would lose the word that gives it its meaning.
        ViewThatFits(in: .horizontal) {
            reminder(L("Enter confirms nothing · %@ allow · %@ deny", model.settings.allowKey.label, model.settings.denyKey.label))
            reminder(L("%@ allow · %@ deny", model.settings.allowKey.label, model.settings.denyKey.label))
        }
    }

    private func reminder(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11.5))
            .foregroundStyle(Palette.text3)
            .lineLimit(1)
            .allowsHitTesting(false)
    }
}

/// What was decided today. There is no text of commands, answers or plans in it, and none is kept.
private struct RequestHistory: View {
    @Bindable var model: AppModel
    var wide: Bool

    private var mode: DisplayMode { model.settings.displayMode }
    private var decisions: [RequestDecision] { model.hooks.queue.decisions(on: Date()) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L("Decided today · %lld", decisions.count))
                .font(.system(size: 13, weight: .semibold))
                .padding(.leading, 4)
            VStack(spacing: 0) {
                if decisions.isEmpty {
                    Text(L("Nothing yet today."))
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.text2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                } else {
                    columns(
                        time: Text(L("Time")),
                        project: Text(L("Project")),
                        environment: Text(L("Environment")),
                        agent: Text(L("Agent")),
                        action: Text(L("Action")),
                        decision: Text(L("Decision")).frame(maxWidth: .infinity, alignment: .leading),
                        place: Text(L("Answered in")),
                        waited: Text(L("Waited"))
                    )
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Palette.text2)
                    .padding(.vertical, 6)
                    .background(Palette.fill1)
                    ForEach(decisions) { row($0) }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Palette.separator))
            Text(L("The text of commands is not kept in the history. Answers to questions and the text of plans open in the session."))
                .font(.system(size: 11))
                .foregroundStyle(Palette.text3)
                .padding(.leading, 4)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func columns<A: View, B: View, C: View, D: View, E: View, F: View, G: View, H: View>(time: A, project: B, environment: C, agent: D, action: E, decision: F, place: G, waited: H) -> some View {
        HStack(spacing: 10) {
            time.frame(width: 44, alignment: .leading)
            project.frame(width: 92, alignment: .leading)
            if wide {
                environment.frame(width: 104, alignment: .leading)
                agent.frame(width: 104, alignment: .leading)
            }
            // In a narrow table the tool's long name would otherwise push out what it was asked to do.
            action.lineLimit(wide ? 1 : 2).frame(maxWidth: .infinity, alignment: .leading)
            decision.frame(width: 150, alignment: .leading)
            place.frame(width: 122, alignment: .leading)
            waited.frame(width: 44, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .lineLimit(1)
    }

    private func mark(_ outcome: RequestOutcome) -> (StatusGlyph.Kind, Color) {
        switch outcome {
        case .allowed, .answered, .planApproved: return (.done, Palette.done)
        case .denied, .planDenied: return (.failed, Palette.redText)
        case .expired: return (.stopped, Palette.text2)
        case .closedInClaude: return (.idle, Palette.text2)
        }
    }

    @ViewBuilder private func row(_ item: RequestDecision) -> some View {
        if let session = item.session {
            RowButton {
                model.openSession(session)
            } label: {
                line(item)
            }
            .accessibilityHint(L("Opens the session"))
        } else {
            line(item)
        }
    }

    private func line(_ item: RequestDecision) -> some View {
        let shown = mark(item.outcome)
        let what = RequestWords.what(item.brief)
        let action = mode == .technical
            ? Text(item.brief.tool).font(.system(size: 11.5, design: .monospaced)) + Text(verbatim: " · \(what)").foregroundStyle(Palette.text2)
            : Text(what).foregroundStyle(Palette.text2)
        return columns(
            time: Text(WorkFormat.time(item.at)).monospacedDigit().foregroundStyle(Palette.text2),
            project: Text(item.project ?? "—").font(.system(size: 11.5, design: .monospaced)).truncationMode(.middle),
            environment: Text(item.environment ?? "—").foregroundStyle(Palette.text2),
            agent: Text(RequestWords.agent(isMain: item.isMainAgent, title: nil, type: item.agentType, mode: mode)).foregroundStyle(Palette.text2),
            action: action,
            decision: HStack(spacing: 6) {
                StatusGlyph(kind: shown.0, size: 14)
                Text(RequestWords.outcome(item.outcome)).fontWeight(.medium).foregroundStyle(shown.1)
            },
            place: Text(RequestWords.place(item.place)).foregroundStyle(Palette.text2),
            waited: Text(RequestWords.clock(item.waited)).monospacedDigit().foregroundStyle(Palette.text2)
        )
        .font(.system(size: 12))
        .padding(.vertical, wide ? 0 : 3)
        .frame(minHeight: 30)
        .overlay(alignment: .top) { Rectangle().fill(Palette.separator).frame(height: 1) }
        .accessibilityElement(children: .combine)
    }
}
