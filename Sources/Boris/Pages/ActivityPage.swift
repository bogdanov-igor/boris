import BorisCore
import BorisData
import SwiftUI

/// The actions of all sessions in one feed, with filters.
struct ActivityPage: View {
    @Bindable var model: AppModel

    @State private var store: FeedStore
    @State private var query: ActivityQuery
    @State private var opened: Set<String> = []

    /// Only the newest actions are shown, so the end of each file is enough. A big file is read further back only if this holds no steps.
    private static let window: UInt64 = 512 * 1024

    init(model: AppModel, type: ActivityFilter = .all) {
        self.model = model
        _query = State(initialValue: ActivityQuery(type: type))
        _store = State(initialValue: FeedStore(model: model, sessionId: nil, window: Self.window))
    }

    private var sessions: [String: WorkSession] {
        Dictionary(model.work.sessions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    private func shown(_ sessions: [String: WorkSession]) -> [FeedEntry] {
        store.entries.filter { query.matches($0, session: sessions[$0.sessionId]) }
    }

    var body: some View {
        let sessions = sessions
        let entries = shown(sessions)
        VStack(spacing: 0) {
            filters(entries, sessions: sessions)
                .padding(.horizontal, 24)
                .padding(.vertical, 10)
            Rectangle().fill(Palette.separator).frame(height: 1)
            if entries.isEmpty {
                Text(store.loaded ? (query == ActivityQuery() ? L("No actions yet") : L("No actions match these filters")) : L("Reading the logs…"))
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.text2)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                FollowingScroll(ids: entries.map(\.id), alignsToBottom: true, store: store) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if store.startedPartWay {
                            Text(L("Showing the latest steps"))
                                .font(.system(size: 11))
                                .foregroundStyle(Palette.text3)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                        }
                        ForEach(entries) { entry in
                            if let step = entry.step {
                                row(entry, step: step, session: sessions[entry.sessionId])
                            }
                        }
                    }
                    .padding(EdgeInsets(top: 6, leading: 12, bottom: 12, trailing: 12))
                }
            }
        }
        .readsFeed(store)
        .showsDiffs(of: store)
    }

    // MARK: - Filters

    private func filters(_ entries: [FeedEntry], sessions: [String: WorkSession]) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                chips
                Spacer(minLength: 0)
                trailing(entries, sessions: sessions)
            }
            VStack(alignment: .leading, spacing: 8) {
                chips
                HStack(spacing: 8) {
                    trailing(entries, sessions: sessions)
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private var chips: some View {
        HStack(spacing: 4) {
            ForEach(ActivityFilter.allCases) { filter in
                let selected = filter == query.type
                Button {
                    query.type = filter
                } label: {
                    Text(filter.title)
                        .font(.system(size: 11.5))
                        .lineLimit(1)
                        .fixedSize()
                        .foregroundStyle(selected ? Palette.window : Palette.text1)
                        .padding(.horizontal, 9)
                        .frame(height: 22)
                        .background(Capsule().fill(selected ? Palette.text1 : Palette.button))
                        .overlay {
                            if !selected { Capsule().strokeBorder(Palette.buttonBorder, lineWidth: 0.5) }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L("Type"))
    }

    private func trailing(_ entries: [FeedEntry], sessions: [String: WorkSession]) -> some View {
        HStack(spacing: 8) {
            pickMenu(
                title: query.project.map { L("Project: %@", projectTitle($0)) } ?? L("Project: all"),
                label: L("Project"),
                values: Set(model.work.sessions.map { $0.cwd ?? "" }).sorted(),
                name: projectTitle,
                selection: $query.project
            )
            pickMenu(
                title: query.place.map { L("Environment: %@", $0) } ?? L("Environment: all"),
                label: L("Environment"),
                values: Set(model.work.sessions.map { WorkPhrases.environment($0.environment) }).sorted(),
                name: { $0 },
                selection: $query.place
            )
            CopyLink(title: L("Copy all"), font: .system(size: 12), color: Palette.text1) {
                let names = names(sessions)
                return await Task.detached { WorkPhrases.plainText(entries, names: names, cwd: nil) }.value
            }
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(RoundedRectangle(cornerRadius: DesignMetrics.radiusMedium).fill(Palette.button))
            .overlay(RoundedRectangle(cornerRadius: DesignMetrics.radiusMedium).strokeBorder(Palette.buttonBorder, lineWidth: 0.5))
            .fixedSize()
        }
    }

    private func projectTitle(_ path: String) -> String {
        path.isEmpty ? L("Without a project") : URL(fileURLWithPath: path).lastPathComponent
    }

    private func names(_ sessions: [String: WorkSession]) -> [String: String] {
        var names = store.fileNames
        for session in sessions.values { names.merge(SessionFeed.agentNames(session)) { _, tree in tree } }
        return names
    }

    private func pickMenu(title: String, label: String, values: [String], name: @escaping (String) -> String, selection: Binding<String?>) -> some View {
        Menu {
            Button(L("All")) { selection.wrappedValue = nil }
            ForEach(values, id: \.self) { value in
                Button(name(value)) { selection.wrappedValue = value }
            }
        } label: {
            HStack(spacing: 6) {
                Text(title).font(.system(size: 12)).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold)).foregroundStyle(Palette.text2)
            }
        }
        .menuStyle(.button)
        .buttonStyle(PlainActionStyle(height: 24))
        .fixedSize()
        .accessibilityLabel(label)
    }

    // MARK: - Rows

    @ViewBuilder private func row(_ entry: FeedEntry, step: ActivityStep, session: WorkSession?) -> some View {
        let isOpen = opened.contains(entry.id)
        let waiting = SessionFeed.isWaiting(entry, session: session)
        VStack(alignment: .leading, spacing: 0) {
            Button {
                if isOpen { opened.remove(entry.id) } else { opened.insert(entry.id) }
            } label: {
                ActivityRow(
                    step: step,
                    waiting: waiting,
                    project: session?.cwd.map { URL(fileURLWithPath: $0).lastPathComponent } ?? session?.displayName ?? L("Without a project"),
                    projectIsFolder: session?.cwd != nil,
                    place: WorkPhrases.environment(session?.environment),
                    agent: store.agentName(entry.agentId, session: session, short: false),
                    cwd: session?.cwd,
                    now: model.now,
                    isOpen: isOpen
                )
            }
            .buttonStyle(.plain)
            .contextMenu {
                if let session {
                    Button(SessionJump.title(session.environment)) { SessionNavigator.open(session, model: model) }
                }
            }
            if isOpen {
                StepDetails(entry: entry, step: step, cwd: session?.cwd, store: store, technical: true)
                    .padding(EdgeInsets(top: 2, leading: 86, bottom: 8, trailing: 10))
            }
        }
    }
}

/// One action: when, how it went, its type, where it happened, what it touched and how long it took.
private struct ActivityRow: View {
    var step: ActivityStep
    var waiting: Bool
    var project: String
    var projectIsFolder: Bool
    var place: String
    var agent: String
    var cwd: String?
    var now: Date
    var isOpen: Bool

    private var target: String { WorkPhrases.target(step, cwd: cwd) ?? "" }
    /// Words a person or Claude wrote are set in the ordinary font, names of files and commands in the monospaced one.
    private var targetIsWords: Bool { step.kind == .web || (step.kind == .helper && step.tool != "Skill") }

    var body: some View {
        HStack(spacing: 10) {
            // A record from another day says which day as well, and that takes a second line in this narrow column.
            Text(step.startedAt.map { WorkPhrases.time($0, now: now, seconds: true) } ?? "")
                .font(.system(size: 11.5).monospacedDigit())
                .foregroundStyle(Palette.text3)
                .lineLimit(2)
                .frame(width: 58, alignment: .leading)
            StatusGlyph(kind: waiting ? .waiting : StatusGlyph.Kind(step.state), size: 14)
            Text(WorkPhrases.action(WorkAction(tool: step.tool), tool: step.tool))
                .font(.system(size: 11))
                .lineLimit(1)
                .padding(.horizontal, 7)
                .padding(.vertical, 1)
                .background(RoundedRectangle(cornerRadius: DesignMetrics.radiusSmall).fill(Palette.fill2))
                .frame(width: 122, alignment: .leading)
            VStack(alignment: .leading, spacing: 0) {
                Text(project)
                    .font(.system(size: 12.5, weight: .semibold, design: projectIsFolder ? .monospaced : .default))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(verbatim: "\(place) · \(agent)")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.text2)
                    .lineLimit(1)
            }
            .frame(width: 150, alignment: .leading)
            HStack(spacing: 8) {
                Text(target)
                    .font(.system(size: 12, design: targetIsWords ? .default : .monospaced))
                    .lineLimit(1)
                    .truncationMode(step.targetTruncation)
                ChangeCounts(added: step.added, removed: step.removed)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            StepTimer(step: step, waiting: waiting, size: 11.5)
                .frame(width: 90, alignment: .trailing)
        }
        .padding(.horizontal, 10)
        .frame(minHeight: 34)
        .background(RoundedRectangle(cornerRadius: DesignMetrics.radiusMedium).fill(isOpen ? Palette.fill1 : .clear))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}
