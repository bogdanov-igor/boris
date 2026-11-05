import BorisCore
import SwiftUI

/// A changed file and its counts. A click shows every removed and added line.
struct ChangedFileRow: View {
    var file: ChangedFile
    /// The technical view names a file by its path, the simple one by its name.
    var showsPath: Bool
    var session: WorkSession
    var open: (DiffRequest) -> Void

    private var title: String { showsPath ? WorkPhrases.path(file.path, cwd: session.cwd) : file.name }

    var body: some View {
        Button {
            open(DiffRequest(title: title, entries: file.steps))
        } label: {
            HStack(spacing: 8) {
                Text(title)
                    .font(showsPath ? .system(size: 11.5, design: .monospaced) : .system(size: 12.5))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                ChangeCounts(added: file.added, removed: file.removed)
                if showsPath {
                    Text(L("Changes")).font(.system(size: 11.5)).foregroundStyle(Palette.waiting)
                }
            }
            .frame(minHeight: 24)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// The files a session changed, for the side of the session page. It shares what it reads with the feed next to it.
struct SessionChangesView: View {
    @Bindable var model: AppModel
    var session: WorkSession

    var body: some View {
        SessionChangesContent(model: model, session: session).id(session.id)
    }
}

private struct SessionChangesContent: View {
    @Bindable var model: AppModel
    var session: WorkSession
    @State private var store: FeedStore
    /// Its own, so that the feed next to it does not open the same sheet as well.
    @State private var shownDiff: DiffRequest?

    init(model: AppModel, session: WorkSession) {
        self.model = model
        self.session = session
        _store = State(initialValue: FeedStore.forSession(session, model: model))
    }

    private var technical: Bool { model.settings.displayMode == .technical }

    var body: some View {
        let files = SessionFeed.changedFiles(store.entries)
        VStack(alignment: .leading, spacing: technical ? 4 : 6) {
            Text(technical ? L("Changed files · %lld", files.count) : L("Changed files"))
                .font(.system(size: technical ? 11.5 : 13, weight: .semibold))
                .foregroundStyle(technical ? Palette.text2 : Palette.text1)
            if files.isEmpty {
                Text(!store.loaded ? L("Reading the logs…") : technical ? L("No files changed in this session.") : L("Nothing has changed yet."))
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.text2)
            } else {
                ForEach(files.reversed()) { file in
                    ChangedFileRow(file: file, showsPath: technical, session: session) { shownDiff = $0 }
                }
                if !technical {
                    Button(L("View changes")) { shownDiff = DiffRequest(title: L("All changes"), entries: files.flatMap(\.steps)) }
                        .buttonStyle(.plain)
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.waiting)
                }
                if store.startedPartWay {
                    Text(L("Counted from the latest steps only."))
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.text3)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .readsFeed(store)
        .sheet(item: $shownDiff) { request in
            DiffSheet(title: request.title, entries: request.entries, store: store)
        }
    }
}
