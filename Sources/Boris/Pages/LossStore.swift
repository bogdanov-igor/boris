import BorisCore
import BorisData
import Foundation
import Observation

/// What the Losses page shows. The logs are read off the main thread, and only while the page is open.
@MainActor
@Observable
final class LossStore {
    private(set) var book: LossBook?
    private(set) var progress: LossIndex.Progress?
    var period = LossPeriod.month
    var kind: LossKind?
    var project: String?
    var environment: WorkEnvironment?

    private let index = LossIndex(cacheFile: BorisPaths.support.appendingPathComponent(LossIndex.cacheName))
    private var frozen = false
    private var updated = false

    private static let interval: Duration = .seconds(10)

    /// Runs for as long as the page is on screen.
    func follow(_ model: AppModel) async {
        guard !frozen else { return }
        while !Task.isCancelled {
            // A closed window keeps its page alive, and it must cost nothing. Before the first scan every session looks gone, and with it all their running agents.
            if model.mainWindowIsOpen, model.loaded { await update(model) }
            try? await Task.sleep(for: Self.interval)
        }
    }

    /// What was read under the old choice of sources must not stay on the page. It comes back from the logs in the next pass.
    func sourcesChanged(_ model: AppModel) {
        guard !frozen else { return }
        book = nil
        updated = false
        if model.page == .losses, model.mainWindowIsOpen, model.loaded {
            Task { await update(model) }
        }
    }

    /// The numbers for the chosen period, without reading the logs again.
    func periodChanged(_ model: AppModel) async {
        guard updated, !frozen else { return }
        await publish(model)
    }

    private func update(_ model: AppModel) async {
        let folder = model.settings.claudeFolder
        let index = index
        let filter = model.sourceFilter
        let reader = Task.detached(priority: .utility) { [weak self] in
            let paths = ClaudePaths.resolve(custom: folder)
            await index.update(roots: [paths] + ClaudeFolders.others(besides: paths), filter: filter) { progress in
                guard progress.done == progress.total || progress.done % 50 == 0 else { return }
                Task { @MainActor in self?.progress = progress }
            }
        }
        await withTaskCancellationHandler {
            await reader.value
        } onCancel: {
            reader.cancel()
        }
        // Leaving the page stops the reading, and what was read is kept for next time.
        guard !Task.isCancelled else { return }
        updated = true
        await publish(model)
        progress = nil
    }

    /// What went wrong in one session besides its fallen agents, by kind and counted as the Losses page counts it. Only that session's files are read.
    /// Nil only while it is being read for the first time. A snapshot has no logs, and nothing in them.
    func steps(of session: String, model: AppModel) async -> [LossKind: Int]? {
        guard !frozen else { return [:] }
        let folder = model.settings.claudeFolder
        let index = index
        let filter = model.sourceFilter
        let live = model.sessionsAtWork
        let entries = await Task.detached(priority: .utility) {
            let paths = ClaudePaths.resolve(custom: folder)
            await index.update(session: session, roots: [paths] + ClaudeFolders.others(besides: paths), filter: filter)
            return await index.history(session: session, live: live)
        }.value
        var kinds: [LossKind: Int] = [:]
        for entry in entries where entry.kind != .crash { kinds[entry.kind, default: 0] += entry.count }
        return kinds
    }

    private func publish(_ model: AppModel) async {
        let chosen = period
        let live = model.sessionsAtWork
        let fresh = await index.book(period: chosen, tokens: model.usage.records, live: live, now: Date())
        if chosen == period, fresh != book { book = fresh }
    }

    #if DEBUG
    func showForSnapshot(_ history: LossHistory?, agentTokens: [String: Int], now: Date) {
        frozen = true
        book = history.map { LossBook(history: $0, period: period, agentTokens: agentTokens, now: now) }
    }

    func showProgressForSnapshot(done: Int, total: Int) {
        book = nil
        progress = LossIndex.Progress(done: done, total: total)
    }
    #endif
}
