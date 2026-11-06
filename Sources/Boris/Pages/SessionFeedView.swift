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
    @State private var folding = FeedFolding()
    /// The record a failure was opened at. It stays marked until the person leaves the page.
    @State private var marked: String?

    init(model: AppModel, session: WorkSession) {
        self.model = model
        self.session = session
        _store = State(initialValue: FeedStore.forSession(session, model: model))
        #if DEBUG
        _folding = State(initialValue: FeedFolding(opened: model.feedForSnapshot?.opened ?? []))
        #endif
    }

    private var mode: DisplayMode { model.settings.displayMode }
    private var entries: [FeedEntry] { SessionFeed.visible(store.entries, agent: agent) }

    /// Only once everything is read: the record nearest in time may belong to an agent that has not been read yet.
    private var targetEntry: String? {
        guard store.loaded, let target = model.feedTarget else { return nil }
        return SessionFeed.place(ofFailure: target, in: entries)
    }

    private var thinkers: [FeedStore.Thinker] {
        // The simple view tells about everybody at once, and has no way to choose.
        guard mode == .technical else { return store.thinking }
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
        .onChange(of: model.feedAgent, initial: true) { _, chosen in
            switch chosen {
            case nil: agent = .all
            case session.id: agent = .one(nil)
            case let id?: agent = .one(id)
            }
        }
        // Going there happens once, and the scroll view holds on to it from here. A feed that starts later than the failure just stays at its end.
        .task(id: TargetWait(target: model.feedTarget, loaded: store.loaded)) {
            guard store.loaded, model.feedTarget != nil else { return }
            if let targetEntry { marked = targetEntry }
            await Task.yield()
            model.feedTarget = nil
        }
    }

    // MARK: - Technical

    private var technical: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text(L("Feed")).font(.system(size: 12.5, weight: .semibold))
                agentMenu
                Spacer(minLength: 0)
                CopyLink(title: L("Copy all"), font: .system(size: 12)) {
                    let (entries, names, cwd) = (entries, names, session.cwd)
                    return await Task.detached { WorkPhrases.plainText(entries, names: names, cwd: cwd) }.value
                }
                .padding(.horizontal, 8)
            }
            .padding(.horizontal, 16)
            .frame(height: 40)
            Rectangle().fill(Palette.separator).frame(height: 1)
            if entries.isEmpty, thinkers.isEmpty {
                empty
            } else {
                FollowingScroll(ids: entries.map(\.id), target: targetEntry, store: store) {
                    LazyVStack(alignment: .leading, spacing: 3) {
                        if store.startedPartWay { partWayNote }
                        ForEach(entries) { entry in
                            row(entry)
                                .background(RoundedRectangle(cornerRadius: DesignMetrics.radiusMedium).fill(entry.id == marked ? Palette.redSoft : .clear))
                        }
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
            Button(L("All agents")) { model.feedAgent = nil }
            Button(L("Main agent")) { model.feedAgent = session.id }
            ForEach(store.agentIds, id: \.self) { id in
                Button(store.agentName(id, session: session)) { model.feedAgent = id }
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
                isOpen: folding.isOpen(step),
                waiting: SessionFeed.isWaiting(entry, session: session),
                store: store
            ) {
                folding.toggle(step)
            }
        }
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

    /// The simple view names nobody, so one line says it all. Past a few, names say nothing either: a big workflow can have a hundred agents thinking at once.
    @ViewBuilder private func thinkingRows(named: Bool) -> some View {
        let thinkers = thinkers
        if !named {
            if !thinkers.isEmpty { FeedThinkingRow(agent: nil) }
        } else if thinkers.count > 3 {
            FeedThinkingRow(agent: WorkPhrases.agents(thinkers.count))
        } else {
            ForEach(thinkers) { thinker in
                FeedThinkingRow(agent: store.agentName(thinker.agentId, session: session))
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
        Text(store.loaded ? L("No records yet") : L("Reading the logs…"))
            .font(.system(size: 12.5))
            .foregroundStyle(Palette.text2)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Simple

    private var simple: some View {
        let lines = FeedSummary.lines(store.entries)
        return VStack(alignment: .leading, spacing: 0) {
            Text(L("What’s done")).font(.system(size: 13, weight: .semibold)).padding(.bottom, 6)
            if lines.isEmpty, thinkers.isEmpty {
                empty
            } else {
                FollowingScroll(ids: lines.map(\.id), store: store) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(lines) { line in
                            FeedLineRow(line: line, now: model.now, store: store, session: session)
                        }
                        thinkingRows(named: false)
                    }
                }
            }
        }
    }
}

private struct TargetWait: Equatable {
    var target: FeedTarget?
    var loaded: Bool
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
                    Text(waiting ? WorkPhrases.waiting(session.waitingFor, mode: .simple) : line.text)
                        .font(.system(size: 13))
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    ChangeCounts(added: line.added, removed: line.removed)
                    if waiting {
                        // The words on the left already say so.
                    } else if let step = runningStep {
                        StepTimer(step: step, size: 11.5)
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
                    // A change that failed has nothing to show but the name of its file.
                    if line.kind == .read || line.state == .failed {
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
