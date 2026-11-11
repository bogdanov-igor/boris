import BorisCore
import BorisData
import Foundation
import Observation

/// What the usage page shows and what it is set to. The sums are added up off the main thread and only when the logs changed,
/// so a screen looks a number up and a scan costs nothing here.
@MainActor
@Observable
final class UsageModel {
    var period = UsagePeriod.week
    var breakdown = TokenBreakdown.days
    /// Nil until the first pass over the logs is done, which is not the same as zero.
    private(set) var book: TokenBook?
    var progress: WorkEngine.TokenProgress?

    @ObservationIgnored var onBuilt: (() -> Void)?
    /// The Projects and Losses pages add up from these same records. They change only when the logs did.
    private(set) var records: [TokenRecord] = []
    /// Who these numbers come from. Added up with them, off the main thread.
    private(set) var sources: Set<SourceID> = []
    /// What the logs of this Mac said, and what remote machines reported. They change at different times.
    @ObservationIgnored private var localRecords: [TokenRecord]?
    @ObservationIgnored private var remoteRecords: [TokenRecord] = []
    @ObservationIgnored private var building = false
    @ObservationIgnored private var buildAgain = false
    @ObservationIgnored private var generation = 0

    /// New numbers from the logs.
    func read(_ records: [TokenRecord]) {
        localRecords = records
        self.records = records + remoteRecords
        build()
    }

    /// New numbers from remote machines. Until the first pass over this Mac's own logs is done, nothing is known yet either way.
    func readRemote(_ records: [TokenRecord]) {
        remoteRecords = records
        guard let localRecords else { return }
        self.records = localRecords + records
        build()
    }

    /// Another Claude folder: nothing is known about it yet. A build still under way must not bring the old numbers back.
    func reset() {
        generation += 1
        localRecords = nil
        records = []
        sources = []
        book = nil
        progress = nil
        building = false
        buildAgain = false
    }

    /// A new day moves every period, even when nothing is being written.
    func noteTime(_ now: Date) {
        guard let book, book.today != Self.dayKey(now) else { return }
        build()
    }

    func spentToday(_ now: Date) -> TokenUsage {
        book?.spent(onDay: Self.dayKey(now)) ?? TokenUsage()
    }

    /// Today's total for a screen. Nothing is known until the first pass over the logs is done, which is not the same as zero.
    func todayText(_ spent: TokenUsage) -> String {
        UsageFormat.total(book == nil ? nil : spent)
    }

    private func build() {
        guard !building else {
            buildAgain = true
            return
        }
        building = true
        let records = records
        let generation = generation
        Task.detached(priority: .utility) { [weak self] in
            let started = SpeedLog.start()
            let book = TokenBook(records: records, now: Date())
            let sources = Self.sources(of: records)
            SpeedLog.loaded(.spendSums, since: started, items: records.count, onMain: false)
            await self?.finish(book, sources: sources, generation: generation)
        }
    }

    private nonisolated static func sources(of records: [TokenRecord]) -> Set<SourceID> {
        var entrypoints = Set<String>()
        for record in records {
            if let entrypoint = record.entrypoint { entrypoints.insert(entrypoint) }
        }
        return Set(entrypoints.compactMap { SourceID(entrypoint: $0) })
    }

    private func finish(_ book: TokenBook, sources: Set<SourceID>, generation: Int) {
        guard generation == self.generation else { return }
        self.book = book
        self.sources = sources
        building = false
        onBuilt?()
        if buildAgain {
            buildAgain = false
            build()
        }
    }

    static func dayKey(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    #if DEBUG
    func showForSnapshot(book: TokenBook?, records: [TokenRecord] = [], progress: WorkEngine.TokenProgress? = nil) {
        self.book = book
        self.records = records
        self.progress = progress
        sources = Self.sources(of: records)
    }
    #endif
}
