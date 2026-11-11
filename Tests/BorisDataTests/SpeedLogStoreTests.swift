@testable import BorisCore
import Darwin
import Foundation
import Testing
@testable import BorisData

/// Hands what this thread notes about speed to a store of the test's own, so lines of other tests running meanwhile stay out of it.
private final class SpeedToStore: LogSink, @unchecked Sendable {
    private let thread = pthread_self()
    private let store: AppLogStore

    init(_ store: AppLogStore) {
        self.store = store
        AppLog.add(self)
    }

    func stop() { AppLog.remove(self) }

    func write(_ record: LogRecord) {
        guard pthread_equal(thread, pthread_self()) != 0, record.area == .speed else { return }
        store.write(record)
    }

    func flush() {}
}

private func ms(_ value: Double) -> UInt64 {
    UInt64(value * 1_000_000)
}

@Suite("Скорость: в файле журнала", .serialized)
struct SpeedLogStoreTests {
    @Test("Одна и та же остановка раз за разом сворачивается в одну строку со счётчиком")
    func repeatsCollapse() {
        let folder = TempFolder()
        let store = AppLogStore(file: folder.url.appendingPathComponent("app.log"))
        let sink = SpeedToStore(store)
        SpeedLog.reset()
        SpeedLog.isWatching = true
        defer {
            sink.stop()
            SpeedLog.reset()
        }
        SpeedLog.appeared(.session)
        // Every second the same page holds the main thread a little differently long: 160, 170, 155, 165 ms.
        for (index, busy) in [160.0, 170, 155, 165].enumerated() {
            let from = Double(index) * 1000 + 5000
            SpeedLog.mainThread(.waking, now: ms(from))
            SpeedLog.mainThread(.sleeping, now: ms(from + busy))
        }
        // A quick one after them writes nothing, so the run stays one line.
        SpeedLog.mainThread(.waking, now: ms(9000))
        SpeedLog.mainThread(.sleeping, now: ms(9040))
        let records = store.records()
        #expect(records.count == 1)
        #expect(records.first?.message == .mainThreadStalled)
        #expect(records.first?.count == 4)
        #expect(records.first?.values == [.milliseconds(150), .choice(SpeedPlace.session), .choice(SpeedAction.none)])
    }

    @Test("Другая длительность — уже другая строка")
    func differentStaysApart() {
        let folder = TempFolder()
        let store = AppLogStore(file: folder.url.appendingPathComponent("app.log"))
        let sink = SpeedToStore(store)
        SpeedLog.reset()
        SpeedLog.isWatching = true
        defer {
            sink.stop()
            SpeedLog.reset()
        }
        SpeedLog.loaded(.activity, since: ms(0), items: 412, onMain: false, now: ms(310))
        SpeedLog.loaded(.activity, since: ms(0), items: 408, onMain: false, now: ms(290))
        SpeedLog.loaded(.activity, since: ms(0), items: 418, onMain: false, now: ms(820))
        let records = store.records()
        #expect(records.map(\.count) == [2, 1])
        #expect(records.first?.values == [.choice(SpeedLoad.activity), .milliseconds(300), .number(410), .flag(false)])
    }
}
