import BorisCore
import SwiftUI

/// What a session is doing, entry by entry. It fills the space it is given and scrolls by itself, so it does not go inside another scroll view.
struct SessionFeedView: View {
    @Bindable var model: AppModel
    var session: WorkSession

    var body: some View {
        SessionFeedContent(model: model, session: session).id(session.id)
    }
}

private struct SessionFeedContent: View {
    @Bindable var model: AppModel
    var session: WorkSession

    @State private var store: FeedStore
    @State private var agent = AgentFilter.all
    /// Steps the person opened or closed by hand. Everything else follows the default.
    @State private var toggled: Set<String> = []

    init(model: AppModel, session: WorkSession) {
        self.model = model
        self.session = session
        _store = State(initialValue: FeedStore.forSession(session, model: model))
        #if DEBUG
        _toggled = State(initialValue: model.feedForSnapshot?.opened ?? [])
        #endif
    }

    private var mode: DisplayMode { model.settings.displayMode }
    private var entries: [FeedEntry] { SessionFeed.visible(store.entries, agent: agent) }

    private var thinkers: [FeedStore.Thinker] {
        switch agent {
        case .all: return store.thinking
        case .one(let id): return store.thinking.filter { $0.agentId == id }
        }
    }

    var body: some View {
        Group {
            if mode == .technical { technical } else { simple }
        }
        .readsFeed(store)
        .showsDiffs(of: store)
    }

    // MARK: - Technical

    private var technical: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text(L("Feed")).font(.system(size: 12.5, weight: .semibold))
                agentMenu
                Spacer(minLength: 0)
                CopyLink(title: L("Copy all"), font: .system(size: 12)) {
                    WorkPhrases.plainText(entries, names: names, cwd: session.cwd)
                }
                .padding(.horizontal, 8)
            }
            .padding(.horizontal, 16)
            .frame(height: 40)
            Rectangle().fill(Palette.separator).frame(height: 1)
            if store.loaded, entries.isEmpty, thinkers.isEmpty {
                empty
            } else {
                FollowingScroll(ids: entries.map(\.id)) {
                    LazyVStack(alignment: .leading, spacing: 3) {
                        if store.startedPartWay { partWayNote }
                        ForEach(entries) { row($0) }
                        thinkingRows(named: true)
                    }
                    .padding(EdgeInsets(top: 12, leading: 16, bottom: 20, trailing: 16))
                }
            }
        }
    }

    private var names: [String: String] {
        var names = store.fileNames
        names.merge(SessionFeed.agentNames(session)) { _, tree in tree }
        return names
    }

    private var agentMenu: some View {
        Menu {
            Button(L("All agents")) { agent = .all }
            Button(L("Main agent")) { agent = .one(nil) }
            ForEach(store.agentIds, id: \.self) { id in
                Button(store.agentName(id, session: session)) { agent = .one(id) }
            }
        } label: {
            HStack(spacing: 5) {
                Text(menuTitle).font(.system(size: 12)).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold)).foregroundStyle(Palette.text2)
            }
        }
        .menuStyle(.button)
        .buttonStyle(PlainActionStyle(height: 22))
        .fixedSize()
        .accessibilityLabel(L("Agent"))
    }

    private var menuTitle: String {
        switch agent {
        case .all: return L("All agents")
        case .one(let id): return store.agentName(id, session: session, short: false)
        }
    }

    @ViewBuilder private func row(_ entry: FeedEntry) -> some View {
        switch entry.item {
        case .prompt(_, let text, let at):
            FeedPromptCard(title: promptTitle(entry, at: at), text: text)
        case .note(_, let text, let at):
            FeedNote(title: at.map { L("Claude’s note · %@", clock($0)) } ?? L("Claude’s note"), text: text)
        case .step(let step):
            FeedStepRow(
                entry: entry,
                step: step,
                agent: store.agentName(entry.agentId, session: session),
                cwd: session.cwd,
                now: model.now,
                isOpen: isOpen(step),
                waiting: SessionFeed.isWaiting(entry, session: session),
                store: store
            ) {
                if toggled.contains(step.id) { toggled.remove(step.id) } else { toggled.insert(step.id) }
            }
        }
    }

    /// A step that failed or is still going is what the person came to see, so it starts open.
    private func isOpen(_ step: ActivityStep) -> Bool {
        let openByDefault = step.state == .running || step.state == .failed
        return openByDefault != toggled.contains(step.id)
    }

    private func clock(_ date: Date) -> String {
        WorkPhrases.time(date, now: model.now, seconds: false)
    }

    private func promptTitle(_ entry: FeedEntry, at: Date?) -> String {
        guard entry.agentId == nil else {
            return L("Task of %@", store.agentName(entry.agentId, session: session))
        }
        return at.map { L("You · %@", clock($0)) } ?? L("You")
    }

    /// Past a few, names say nothing: a big workflow can have a hundred agents thinking at once.
    @ViewBuilder private func thinkingRows(named: Bool) -> some View {
        let thinkers = thinkers
        if thinkers.count > 3 {
            FeedThinkingRow(agent: named ? WorkPhrases.agents(thinkers.count) : nil)
        } else {
            ForEach(thinkers) { thinker in
                FeedThinkingRow(agent: named ? store.agentName(thinker.agentId, session: session) : nil)
            }
        }
    }

    private var partWayNote: some View {
        Text(L("Showing the latest steps"))
            .font(.system(size: 11))
            .foregroundStyle(Palette.text3)
            .padding(.bottom, 4)
    }

    private var empty: some View {
        Text(L("No records yet"))
            .font(.system(size: 12.5))
            .foregroundStyle(Palette.text2)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Simple

    private var simple: some View {
        let lines = FeedSummary.lines(store.entries)
        return VStack(alignment: .leading, spacing: 0) {
            Text(L("What’s done")).font(.system(size: 13, weight: .semibold)).padding(.bottom, 6)
            if store.loaded, lines.isEmpty, thinkers.isEmpty {
                empty
            } else {
                FollowingScroll(ids: lines.map(\.id)) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(lines) { line in
                            FeedLineRow(line: line, now: model.now, store: store, session: session)
                        }
                        if !thinkers.isEmpty { thinkingRows(named: false) }
                    }
                }
            }
        }
    }
}

/// A line of the simple view. A line about files opens into those files.
private struct FeedLineRow: View {
    var line: FeedLine
    var now: Date
    var store: FeedStore
    var session: WorkSession
    @State private var isOpen = false

    private var canOpen: Bool { !line.files.isEmpty && (line.kind == .read || line.kind == .edit || line.kind == .write) }

    private var runningStep: ActivityStep? {
        line.state == .running ? line.steps.last?.step : nil
    }

    private var waiting: Bool {
        line.steps.last.map { SessionFeed.isWaiting($0, session: session) } ?? false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                if canOpen { isOpen.toggle() }
            } label: {
                HStack(spacing: 10) {
                    StatusGlyph(kind: waiting ? .waiting : StatusGlyph.Kind(line.state), size: 14).frame(width: 16)
                    Text(line.text)
                        .font(.system(size: 13))
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    ChangeCounts(added: line.added, removed: line.removed)
                    if let step = runningStep {
                        StepTimer(step: step, waiting: waiting, size: 11.5)
                    } else if let at = line.at {
                        Text(WorkPhrases.time(at, now: now, seconds: false))
                            .font(.system(size: 11.5).monospacedDigit())
                            .foregroundStyle(Palette.text2)
                            .fixedSize()
                    }
                    if canOpen {
                        Image(systemName: isOpen ? "chevron.down" : "chevron.right")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(Palette.text2)
                            .frame(width: 10)
                    }
                }
                .frame(minHeight: 32)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if isOpen {
                VStack(alignment: .leading, spacing: 0) {
                    if line.kind == .read {
                        ForEach(line.files, id: \.self) { path in
                            Text(URL(fileURLWithPath: path).lastPathComponent)
                                .font(.system(size: 12))
                                .foregroundStyle(Palette.text2)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .frame(minHeight: 24)
                        }
                    } else {
                        ForEach(SessionFeed.changedFiles(line.steps)) { file in
                            ChangedFileRow(file: file, showsPath: false, session: session) { store.shownDiff = $0 }
                        }
                    }
                }
                .padding(EdgeInsets(top: 0, leading: 26, bottom: 6, trailing: 0))
            }
            Rectangle().fill(Palette.separator).frame(height: 1)
        }
    }
}
