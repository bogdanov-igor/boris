import Foundation
import Testing
@testable import BorisCore

/// Hears only its own thread, because other tests log at the same time.
private final class SpeedCapture: LogSink, @unchecked Sendable {
    private let lock = NSLock()
    private var heard: [LogRecord] = []
    private let thread = pthread_self()

    init() { AppLog.add(self) }

    func stop() { AppLog.remove(self) }

    func write(_ record: LogRecord) {
        guard pthread_equal(thread, pthread_self()) != 0, record.area == .speed else { return }
        lock.withLock { heard.append(record) }
    }

    func flush() {}

    var records: [LogRecord] { lock.withLock { heard } }

    func of(_ message: LogMessage) -> [[LogValue]] {
        records.filter { $0.message == message }.map(\.values)
    }
}

/// Milliseconds on the fake clock, as the nanoseconds the real one gives.
private func ms(_ value: Double) -> UInt64 {
    UInt64(value * 1_000_000)
}

private let threshold = ms(150)

@Suite("Скорость: сторож главного потока")
struct StallWatchTests {
    @Test("Занятость — это промежуток между отметками, а сон не считается")
    func gaps() {
        var watch = StallWatch()
        #expect(watch.mark(.waking, at: ms(0), threshold: threshold) == nil)
        #expect(watch.mark(.working, at: ms(100), threshold: threshold) == nil)
        #expect(watch.mark(.working, at: ms(300), threshold: threshold) == ms(200))
        #expect(watch.mark(.sleeping, at: ms(310), threshold: threshold) == nil)
        // Five seconds of rest, then a short wake.
        #expect(watch.mark(.waking, at: ms(5310), threshold: threshold) == nil)
        #expect(watch.mark(.sleeping, at: ms(5320), threshold: threshold) == nil)
        // A long piece of work that ends in drawing.
        #expect(watch.mark(.waking, at: ms(9000), threshold: threshold) == nil)
        #expect(watch.mark(.sleeping, at: ms(9400), threshold: threshold) == ms(400))
    }

    @Test("Ровно на пороге уже занятость, чуть ниже — ещё нет")
    func edge() {
        var watch = StallWatch()
        _ = watch.mark(.waking, at: ms(0), threshold: threshold)
        #expect(watch.mark(.working, at: ms(149), threshold: threshold) == nil)
        #expect(watch.mark(.working, at: ms(299), threshold: threshold) == ms(150))
    }

    @Test("Первая отметка после запуска ничего не меряет")
    func firstMark() {
        var watch = StallWatch()
        #expect(watch.mark(.working, at: ms(10_000), threshold: threshold) == nil)
        #expect(watch.mark(.sleeping, at: ms(10_001), threshold: threshold) == nil)
    }
}

@Suite("Скорость: что попадает в журнал", .serialized)
struct SpeedLogTests {
    private func fresh() -> SpeedCapture {
        SpeedLog.reset()
        SpeedLog.isWatching = true
        return SpeedCapture()
    }

    private func done(_ capture: SpeedCapture) {
        capture.stop()
        SpeedLog.reset()
    }

    @Test("Округление: до 50 мс в пределах секунды, и две значащие цифры у количества")
    func rounding() {
        #expect(SpeedLog.rounded(milliseconds: 0) == 0)
        #expect(SpeedLog.rounded(milliseconds: 124) == 100)
        #expect(SpeedLog.rounded(milliseconds: 125) == 150)
        #expect(SpeedLog.rounded(milliseconds: 990) == 1000)
        #expect(SpeedLog.rounded(milliseconds: 1100) == 1000)
        #expect(SpeedLog.rounded(milliseconds: 6400) == 6000)
        #expect(SpeedLog.roughly(87) == 87)
        #expect(SpeedLog.roughly(150) == 150)
        #expect(SpeedLog.roughly(1234) == 1200)
        #expect(SpeedLog.roughly(99_999) == 100_000)
    }

    @Test("Быстрый переход не оставляет строки, медленный оставляет: страница, время, действие")
    func pageThreshold() {
        let capture = fresh()
        defer { done(capture) }
        SpeedLog.began(.choosePage, to: .activity, now: ms(1000))
        SpeedLog.appeared(.activity)
        SpeedLog.mainThread(.sleeping, now: ms(1060))
        #expect(capture.of(.pageShown).isEmpty)

        SpeedLog.began(.choosePage, to: .losses, now: ms(2000))
        SpeedLog.appeared(.losses)
        SpeedLog.mainThread(.sleeping, now: ms(2260))
        #expect(capture.of(.pageShown) == [[.choice(SpeedPlace.losses), .milliseconds(250), .choice(SpeedAction.choosePage)]])
    }

    @Test("Переход ждёт кадра, на котором новая страница уже есть")
    func waitsForPage() {
        let capture = fresh()
        defer { done(capture) }
        SpeedLog.appeared(.now)
        SpeedLog.began(.openSession, to: .session, now: ms(0))
        SpeedLog.mainThread(.sleeping, now: ms(30))
        #expect(capture.of(.pageShown).isEmpty)
        SpeedLog.appeared(.session)
        SpeedLog.mainThread(.sleeping, now: ms(410))
        #expect(capture.of(.pageShown) == [[.choice(SpeedPlace.session), .milliseconds(400), .choice(SpeedAction.openSession)]])
        // Done once: the next frame says nothing more.
        SpeedLog.mainThread(.sleeping, now: ms(900))
        #expect(capture.of(.pageShown).count == 1)
    }

    @Test("Время идёт от самого клика, даже когда кнопка назвала себя позже")
    func fromTheClick() {
        let capture = fresh()
        defer { done(capture) }
        SpeedLog.began(.click, now: ms(0))
        SpeedLog.began(.choosePage, to: .spend, now: ms(40))
        SpeedLog.appeared(.spend)
        SpeedLog.mainThread(.sleeping, now: ms(200))
        #expect(capture.of(.pageShown) == [[.choice(SpeedPlace.spend), .milliseconds(200), .choice(SpeedAction.choosePage)]])
    }

    @Test("Долгая кнопка записана по имени и странице, быстрая — нет")
    func slowButton() {
        let capture = fresh()
        defer { done(capture) }
        SpeedLog.appeared(.activity)
        SpeedLog.began(.changeFilter, now: ms(0))
        SpeedLog.mainThread(.sleeping, now: ms(80))
        SpeedLog.began(.click, now: ms(1000))
        SpeedLog.mainThread(.sleeping, now: ms(1130))
        #expect(capture.of(.actionSlow) == [[.choice(SpeedAction.click), .milliseconds(150), .choice(SpeedPlace.activity)]])
    }

    @Test("Страница, которая так и не появилась, не записана ни сразу, ни потом")
    func neverAppeared() {
        let capture = fresh()
        defer { done(capture) }
        SpeedLog.appeared(.now)
        SpeedLog.began(.choosePage, to: .walrus, now: ms(0))
        SpeedLog.mainThread(.sleeping, now: ms(11_000))
        SpeedLog.appeared(.walrus)
        SpeedLog.mainThread(.sleeping, now: ms(11_100))
        #expect(capture.of(.pageShown).isEmpty)
    }

    @Test("Остановка главного потока: сколько, где и после чего, а давнее действие не приписано")
    func stalls() {
        let capture = fresh()
        defer { done(capture) }
        SpeedLog.appeared(.session)
        SpeedLog.mainThread(.waking, now: ms(1000))
        SpeedLog.did(.scanApplied, now: ms(1010))
        SpeedLog.mainThread(.sleeping, now: ms(1400))
        // Long after anything was done.
        SpeedLog.mainThread(.waking, now: ms(10_000))
        SpeedLog.mainThread(.working, now: ms(10_120))
        SpeedLog.mainThread(.sleeping, now: ms(10_420))
        #expect(capture.of(.mainThreadStalled) == [
            [.milliseconds(400), .choice(SpeedPlace.session), .choice(SpeedAction.scanApplied)],
            [.milliseconds(300), .choice(SpeedPlace.session), .choice(SpeedAction.none)],
        ])
    }

    @Test("Загрузка: ниже порога молчит, выше — имя, время, количество и поток")
    func loads() {
        let capture = fresh()
        defer { done(capture) }
        SpeedLog.loaded(.sessionFeed, since: ms(0), items: 1234, onMain: false, now: ms(90))
        SpeedLog.loaded(.sessionFeed, since: ms(0), items: 1234, onMain: false, now: ms(260))
        #expect(capture.of(.loadSlow) == [[.choice(SpeedLoad.sessionFeed), .milliseconds(250), .number(1200), .flag(false)]])
        let value = SpeedLog.measure(.projectSums, items: \.count) { () -> [Int] in
            usleep(120_000)
            return [1, 2, 3]
        }
        #expect(value == [1, 2, 3])
        let measured = capture.of(.loadSlow).last
        #expect(measured?.first == .choice(SpeedLoad.projectSums))
        #expect(measured?[2] == .number(3))
        #expect(measured?.last == .flag(pthread_main_np() != 0))
    }

    @Test("Без сторожа ничего из того, что делает человек, не отслеживается")
    func notWatching() {
        let capture = fresh()
        defer { done(capture) }
        SpeedLog.isWatching = false
        SpeedLog.began(.choosePage, to: .now, now: ms(0))
        SpeedLog.appeared(.now)
        SpeedLog.mainThread(.waking, now: ms(0))
        SpeedLog.mainThread(.sleeping, now: ms(5000))
        #expect(capture.records.isEmpty)
    }

    @Test("Для замера всё точно и без порога, кроме самых коротких остановок")
    func everything() {
        let capture = fresh()
        defer { done(capture) }
        SpeedLog.thresholds = .everything
        SpeedLog.began(.choosePage, to: .now, now: ms(0))
        SpeedLog.appeared(.now)
        SpeedLog.mainThread(.waking, now: ms(0))
        SpeedLog.mainThread(.working, now: ms(10))
        SpeedLog.mainThread(.sleeping, now: ms(37))
        #expect(capture.of(.pageShown) == [[.choice(SpeedPlace.now), .milliseconds(37), .choice(SpeedAction.choosePage)]])
        #expect(capture.of(.mainThreadStalled).isEmpty)
    }

    @Test("Каждая строка читается обратно из файла целиком")
    func linesParse() {
        let capture = fresh()
        defer { done(capture) }
        SpeedLog.appeared(.settingsLog)
        SpeedLog.began(.chooseSettingsSection, to: .settingsLog, now: ms(0))
        SpeedLog.mainThread(.waking, now: ms(0))
        SpeedLog.mainThread(.sleeping, now: ms(700))
        SpeedLog.loaded(.losses, since: ms(0), items: 5, onMain: true, now: ms(3000))
        let text = capture.records.map(LogFile.line).joined()
        let back = LogFile.parse(Data(text.utf8))
        #expect(back.count == capture.records.count)
        #expect(back.map(\.values) == capture.records.map(\.values))
        #expect(back.allSatisfy { $0.area == .speed && !$0.text.isEmpty })
    }
}
