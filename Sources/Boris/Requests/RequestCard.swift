import BorisCore
import BorisData
import SwiftUI

/// The frame every card shares: one component for the notch, the mini window and the main window.
private struct CardFrame<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 9) { content() }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(Palette.pop))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Palette.separator, lineWidth: 0.5))
    }
}

/// The project, where it runs and who asks. A plain text, so that a long name wraps instead of pushing the card apart.
private struct CardMeta: View {
    var project: String
    var projectIsFolder: Bool
    var details: [String]
    var technical: String

    var body: some View {
        var line = Text(project)
            .font(.system(size: 11.5, design: projectIsFolder ? .monospaced : .default))
            .foregroundStyle(Palette.text1)
        for detail in details where !detail.isEmpty {
            line = line + Text(verbatim: " · ") + Text(detail)
        }
        if !technical.isEmpty {
            line = line + Text(verbatim: " · ") + Text(technical).font(.system(size: 11, design: .monospaced))
        }
        return line
            .font(.system(size: 11.5))
            .foregroundStyle(Palette.text2)
            .lineLimit(3)
            .truncationMode(.middle)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A button of the card, with its key shown when the key acts on this card.
private struct CardButton: View {
    var title: String
    var hint: String?
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(title)
                if let hint {
                    Text(verbatim: hint).font(.system(size: 11)).foregroundStyle(Palette.text3)
                }
            }
        }
        .buttonStyle(PlainActionStyle(height: 26))
    }
}

/// Keeps buttons on one line while they fit. A card is narrow in the mini window, and the words are long in Russian.
private struct CardButtons<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                content()
            }
            VStack(alignment: .trailing, spacing: 6) { content() }
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }
}

/// A request that can be answered right here, with all of what is being asked.
struct RequestCard: View {
    @Bindable var model: AppModel
    var request: PendingPermission
    var surface: RequestPlace
    /// More room for a plan on the Requests page.
    var roomy = false

    @State private var token = UUID()
    @FocusState private var reasonFocused: Bool

    private var hooks: HookController { model.hooks }
    private var mode: DisplayMode { model.settings.displayMode }
    private var draft: RequestDraft { hooks.draft(request.id) }
    private var session: WorkSession? { hooks.queue.session(request.session) }

    /// Only one card shows the keys, because they act on only one.
    private var keysHere: Bool { hooks.hotKeyTarget?.id == request.id && !hooks.keysTaken }
    private var allowHint: String? { keysHere ? model.settings.allowKey.label : nil }
    private var denyHint: String? { keysHere ? model.settings.denyKey.label : nil }

    private var reason: Binding<String> {
        Binding { draft.reason } set: { text in hooks.updateDraft(request.id) { $0.reason = text } }
    }

    private var agentName: String {
        let title = session?.root.flattened.first { $0.id == request.agent }?.title
        return RequestWords.agent(isMain: request.agent == nil, title: title, type: request.agentType, mode: mode)
    }

    var body: some View {
        CardFrame {
            header
            CardMeta(
                project: RequestWords.project(request.project, session: session, id: request.session, mode: mode),
                projectIsFolder: request.project != nil,
                details: [session.map { WorkPhrases.environment($0.environment) } ?? "", agentName],
                technical: mode == .technical ? RequestWords.technicalMeta(request) : ""
            )
            content
            if draft.denying { reasonField(L("Reason for Claude, optional"), prompt: L("For example: make a backup first")) }
            if case .plan = request.content { reasonField(L("Comment, optional"), prompt: "") }
            buttons
        }
        .background {
            RequestWindowProbe { shows in
                hooks.noteCard(token, request: request.id, windowShows: shows)
            } onGone: {
                hooks.forgetCard(token)
            }
        }
        // A card scrolled out of its list is off screen as far as the keys are concerned.
        .onGeometryChange(for: Bool.self) { proxy in
            guard let visible = proxy.bounds(of: .scrollView) else { return true }
            let shown = visible.intersection(CGRect(origin: .zero, size: proxy.size)).height
            return shown >= min(proxy.size.height, visible.height) / 2
        } action: { inView in
            hooks.noteCard(token, request: request.id, inView: inView)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            StatusGlyph(kind: .waiting)
            Text(RequestWords.title(request, denying: draft.denying, mode: mode))
                .font(.system(size: 13, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(L("%@ of %@", RequestWords.clock(request.deadline.timeIntervalSince(context.date)), RequestWords.clock(request.deadline.timeIntervalSince(request.askedAt))))
                    .font(.system(size: 11.5, design: .monospaced).monospacedDigit())
                    .foregroundStyle(Palette.text2)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
    }

    @ViewBuilder private var content: some View {
        switch request.content {
        case .command(let command, let unsandboxed):
            RequestTextBox(text: command)
            if unsandboxed { note(L("Runs outside the sandbox"), problem: true) }
        case .file(let path, let lines, _, let everyOccurrence):
            RequestDiffBox(path: RequestWords.path(path, cwd: request.cwd), lines: lines)
            if everyOccurrence { note(L("Replaces every occurrence in the file"), problem: false) }
        case .questions(let questions):
            RequestQuestionsBox(questions: questions) { question in
                draft.picks[question.text] ?? []
            } toggle: { label, question in
                hooks.updateDraft(request.id) { $0.toggle(label, in: question) }
            }
        case .plan(let plan):
            RequestPlanBox(plan: plan, maxHeight: roomy ? 320 : 118)
        case .other(let text):
            RequestTextBox(text: text)
        case .unreadable(let text):
            if !text.isEmpty { RequestTextBox(text: text) }
            note(L("This request cannot be read in full here, so it cannot be allowed from Boris. Answer it in Claude."), problem: false)
        }
    }

    private func note(_ text: String, problem: Bool) -> some View {
        Text(text)
            .font(.system(size: 11.5))
            .foregroundStyle(problem ? Palette.redText : Palette.text2)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func reasonField(_ title: String, prompt: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 11.5)).foregroundStyle(Palette.text2)
            // There is no submit action on purpose: Return in this field sends nothing.
            TextField("", text: reason, prompt: prompt.isEmpty ? nil : Text(prompt), axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .lineLimit(2...4)
                .focused($reasonFocused)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: DesignMetrics.radiusMedium).fill(Palette.window))
                .overlay(RoundedRectangle(cornerRadius: DesignMetrics.radiusMedium).strokeBorder(Palette.separator))
        }
    }

    @ViewBuilder private var buttons: some View {
        switch request.content {
        case .questions(let questions):
            let answers = draft.answers(to: questions)
            CardButtons {
                CardButton(title: L("Answer"), hint: allowHint) {
                    if let answers { hooks.answer(request.id, .answers(answers), via: surface) }
                }
                .disabled(answers == nil)
                .opacity(answers == nil ? 0.45 : 1)
            }
        case .plan:
            CardButtons {
                CardButton(title: L("Deny"), hint: denyHint) { hooks.deny(request.id, via: surface) }
                CardButton(title: L("Approve"), hint: allowHint) { hooks.answer(request.id, .allow, via: surface) }
            }
        case .unreadable:
            CardButtons {
                if SessionNavigator.canOpen(session, pid: pid), let session {
                    CardButton(title: L("Open session"), hint: nil) { SessionNavigator.open(session, model: model) }
                }
                if !draft.denying {
                    CardButton(title: L("Deny"), hint: denyHint) { openReason() }
                } else {
                    denyingButtons
                }
            }
        case .command, .file, .other:
            CardButtons {
                if draft.denying {
                    denyingButtons
                } else {
                    CardButton(title: L("Deny"), hint: denyHint) { openReason() }
                    CardButton(title: L("Allow"), hint: allowHint) { hooks.answer(request.id, .allow, via: surface) }
                }
            }
        }
    }

    @ViewBuilder private var denyingButtons: some View {
        CardButton(title: L("Back"), hint: "Esc") {
            hooks.updateDraft(request.id) { $0.denying = false; $0.reason = "" }
        }
        .keyboardShortcut(.cancelAction)
        CardButton(title: L("Deny"), hint: denyHint) { hooks.deny(request.id, via: surface) }
    }

    private func openReason() {
        hooks.updateDraft(request.id) { $0.denying = true }
        reasonFocused = true
    }

    private var pid: Int32? {
        model.world.sessions.first { $0.sessionId == request.session }.flatMap { $0.isUnlisted ? nil : $0.pid }
    }
}

/// A request Boris cannot answer: the time ran out, the answers are not connected, or the place does not allow it.
struct RequestNoticeCard: View {
    @Bindable var model: AppModel
    var row: RequestRow

    private var mode: DisplayMode { model.settings.displayMode }
    private var session: WorkSession? { model.hooks.queue.session(row.session) }
    private var pid: Int32? {
        model.world.sessions.first { $0.sessionId == row.session }.flatMap { $0.isUnlisted ? nil : $0.pid }
    }

    private var isCowork: Bool { session?.environment == .cowork }

    private var title: String {
        switch row {
        case .open: return ""
        case .expired: return L("Time to answer ran out")
        case .waiting: return isCowork ? L("Waiting for an answer in Cowork") : L("Session is waiting for you")
        }
    }

    private var text: String {
        if case .expired = row { return L("You can still answer in Claude.") }
        if isCowork { return L("This request cannot be answered from Boris. Answer it in Claude Desktop.") }
        if let off = SourcesRequestWords.notAnswered(session, settings: model.settings.sources) { return off }
        switch model.hooks.connection {
        case .notConnected: return L("Answering from Boris is not connected. Answer in the session, or connect answers in a couple of clicks.")
        case .damaged: return L("Answering from Boris is not working right now. Answer in the session, or repair the connection.")
        case .connected: return L("This request did not reach Boris. Answer it in the session.")
        case .settingsUnreadable, .disabledInSettings, .disabledByPolicy: return L("Answering from Boris is not available. Answer in the session.")
        }
    }

    private var offersConnecting: Bool {
        if case .waiting = row, !isCowork, SourcesRequestWords.notAnswered(session, settings: model.settings.sources) == nil { return model.hooks.connection.canConnect }
        return false
    }

    private var project: String {
        switch row {
        case .open(let request): return request.project ?? ""
        case .expired(let request): return RequestWords.project(request.project, session: session, id: row.session, mode: mode)
        case .waiting(let session): return session.name(in: mode)
        }
    }

    private var projectIsFolder: Bool {
        switch row {
        case .open: return true
        case .expired(let request): return request.project != nil || session?.nameIsFolder == true
        case .waiting(let session): return session.nameIsFolder
        }
    }

    private var agent: String {
        if isCowork { return "Cowork" }
        if case .expired(let request) = row {
            let title = session?.root.flattened.first { $0.id == request.agent }?.title
            return RequestWords.agent(isMain: request.agent == nil, title: title, type: request.agentType, mode: mode)
        }
        return L("Main agent")
    }

    var body: some View {
        CardFrame {
            HStack(spacing: 8) {
                if case .expired = row {
                    StatusGlyph(kind: .stopped)
                } else {
                    StatusGlyph(kind: .waiting)
                }
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if case .expired = row {
                    Text(L("expired")).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Palette.text3).lineLimit(1).fixedSize()
                }
            }
            CardMeta(
                project: project,
                projectIsFolder: projectIsFolder,
                details: [isCowork ? "" : (session.map { WorkPhrases.environment($0.environment) } ?? ""), agent],
                technical: ""
            )
            Text(text)
                .font(.system(size: 12.5))
                .lineSpacing(3)
                .foregroundStyle(Palette.text2)
                .fixedSize(horizontal: false, vertical: true)
            CardButtons {
                if offersConnecting {
                    CardButton(title: model.hooks.connection == .damaged ? L("Repair") : L("Connect answers"), hint: nil) { model.hooks.onConnect?() }
                }
                if SessionNavigator.canOpen(session, pid: pid), let session {
                    CardButton(title: isCowork ? L("Open Claude Desktop") : L("Open session"), hint: nil) { SessionNavigator.open(session, model: model) }
                }
            }
        }
    }
}
