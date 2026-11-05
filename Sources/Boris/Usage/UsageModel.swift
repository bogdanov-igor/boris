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
    @ObservationIgnored private var records: [TokenRecord] = []
    @ObservationIgnored private var building = false
    @ObservationIgnored private var buildAgain = false

    /// New numbers from the logs.
    func read(_ records: [TokenRecord]) {
        self.records = records
        build()
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
        Task.detached(priority: .utility) { [weak self] in
            let book = TokenBook(records: records, now: Date())
            await self?.finish(book)
        }
    }

    private func finish(_ book: TokenBook) {
        self.book = book
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
    func showForSnapshot(book: TokenBook?, progress: WorkEngine.TokenProgress? = nil) {
        self.book = book
        self.progress = progress
    }
    #endif
}
