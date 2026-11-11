@testable import BorisCore
import Darwin
import Foundation
import Testing
@testable import BorisData

/// A clock a test moves by hand.
private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ start: Date) { current = start }

    var now: Date { lock.withLock { current } }

    func advance(_ seconds: TimeInterval) {
        lock.withLock { current = current.addingTimeInterval(seconds) }
    }
}

private final class Heard: @unchecked Sendable {
    private let lock = NSLock()
    private var changes: [LogChange] = []

    func add(_ change: LogChange) { lock.withLock { changes.append(change) } }

    var all: [LogChange] { lock.withLock { changes } }
}

/// Hears only its own thread, because other tests log at the same time.
private final class ThreadCapture: LogSink, @unchecked Sendable {
    private let lock = NSLock()
    private var heard: [LogRecord] = []
    private let thread = pthread_self()

    init() { AppLog.add(self) }

    func stop() { AppLog.remove(self) }

    func write(_ record: LogRecord) {
        guard pthread_equal(thread, pthread_self()) != 0 else { return }
        lock.withLock { heard.append(record) }
    }

    func flush() {}

    var messages: [LogMessage] { lock.withLock { heard.map(\.message) } }
    var records: [LogRecord] { lock.withLock { heard } }
}

private let start = Date(timeIntervalSince1970: 1_793_880_000)

private func line(_ number: Int, at date: Date) -> LogRecord {
    LogRecord(at: date, message: .firstRead, values: [.seconds(Double(number)), .number(number)])
}

private func waitUntil(seconds: TimeInterval = 10, _ condition: () -> Bool) async -> Bool {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

@Suite("Журнал: хранение")
struct AppLogStoreTests {
    private func makeStore(_ folder: TempFolder, clock: TestClock? = nil, limits: AppLogStore.Limits = .init()) -> AppLogStore {
        let clock = clock ?? TestClock(start)
        return AppLogStore(file: folder.url.appendingPathComponent("logs/app.log"), limits: limits) { clock.now }
    }

    private func size(_ store: AppLogStore) -> Int {
        // Not through the URL: it remembers what it was told earlier, and a test in a loop would keep seeing the first size.
        ((try? FileManager.default.attributesOfItem(atPath: store.file.path))?[.size] as? Int) ?? 0
    }

    @Test("Границы по заданию: сутки и 5 МБ")
    func limits() {
        #expect(AppLogStore.Limits().keep == 24 * 3600)
        #expect(AppLogStore.Limits().maxBytes == 5 * 1024 * 1024)
    }

    @Test("Файл лежит в папке Boris")
    func place() {
        #expect(AppLogStore.defaultFile.deletingLastPathComponent() == BorisPaths.support)
    }

    @Test("Строки возвращаются в том же порядке, и читать файл может только его хозяин")
    func order() throws {
        let folder = TempFolder()
        let store = makeStore(folder)
        let lines = (0..<5).map { line($0, at: start.addingTimeInterval(Double($0))) }
        for record in lines { store.write(record) }
        #expect(store.records() == lines)
        let mode = try FileManager.default.attributesOfItem(atPath: store.file.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
        #expect(store.newest(2) == Array(lines.suffix(2)))
        #expect(!store.isBroken)
    }

    @Test("Повторы сворачиваются в одну строку со счётчиком")
    func collapse() throws {
        let folder = TempFolder()
        let store = makeStore(folder)
        let same = LogRecord(at: start, message: .hookMessageUnreadable)
        for step in 0..<6 { store.write(LogRecord(at: start.addingTimeInterval(Double(step) * 5), message: .hookMessageUnreadable)) }
        let records = store.records()
        #expect(records.count == 1)
        #expect(records.first?.count == 6)
        #expect(records.first?.lastAt == start.addingTimeInterval(25))
        #expect(records.first?.says(sameAs: same) == true)
        let text = try String(contentsOf: store.file, encoding: .utf8)
        #expect(text.components(separatedBy: "\n").filter { !$0.isEmpty }.count == 2)
    }

    @Test("Повтор после долгой паузы остаётся отдельной строкой: так виден ритм")
    func pause() {
        let folder = TempFolder()
        let store = makeStore(folder)
        for step in 0..<4 { store.write(LogRecord(at: start.addingTimeInterval(Double(step) * 300), message: .soundPlayed, values: [.choice(WalrusSound.alarm)])) }
        let records = store.records()
        #expect(records.count == 4)
        #expect(records.allSatisfy { $0.count == 1 })
    }

    @Test("Другая строка или другое значение прерывают серию")
    func interleaved() {
        let folder = TempFolder()
        let store = makeStore(folder)
        store.write(LogRecord(at: start, message: .soundPlayed, values: [.choice(WalrusSound.alarm)]))
        store.write(LogRecord(at: start, message: .soundPlayed, values: [.choice(WalrusSound.done)]))
        store.write(LogRecord(at: start, message: .soundPlayed, values: [.choice(WalrusSound.alarm)]))
        store.write(LogRecord(at: start, message: .macWoke))
        store.write(LogRecord(at: start, message: .soundPlayed, values: [.choice(WalrusSound.alarm)]))
        #expect(store.records().map(\.count) == [1, 1, 1, 1, 1])
    }

    @Test("Счётчик доходит до зрителя и до файла сам, без закрытия")
    func repeatsReachViewer() async {
        let folder = TempFolder()
        var limits = AppLogStore.Limits()
        limits.repeatFlush = 0.05
        let store = makeStore(folder, limits: limits)
        let heard = Heard()
        #expect(store.attach { heard.add($0) }.isEmpty)
        let first = LogRecord(at: start, message: .macWoke)
        store.write(first)
        store.write(LogRecord(at: start.addingTimeInterval(1), message: .macWoke))
        store.write(LogRecord(at: start.addingTimeInterval(2), message: .macWoke))
        #expect(await waitUntil { heard.all.count == 2 })
        #expect(heard.all == [.added(first), .repeated(count: 3, lastAt: start.addingTimeInterval(2))])
        // Read from another store, as after a restart.
        #expect(AppLogStore(file: store.file) { start }.records().first?.count == 3)
        store.detach()
    }

    @Test("Зритель не теряет строки между чтением и подпиской")
    func attachMisses() async {
        let folder = TempFolder()
        let store = makeStore(folder)
        for number in 0..<50 { store.write(line(number, at: start)) }
        let heard = Heard()
        let read = store.attach { heard.add($0) }
        for number in 50..<60 { store.write(line(number, at: start)) }
        #expect(await waitUntil { heard.all.count == 10 })
        #expect(read.count == 50)
        store.detach()
    }

    @Test("Старше суток: не показывается и уходит из файла")
    func age() throws {
        let folder = TempFolder()
        let clock = TestClock(start)
        let store = makeStore(folder, clock: clock)
        store.write(line(1, at: start))
        clock.advance(23 * 3600)
        store.write(line(2, at: clock.now))
        #expect(store.records().count == 2)
        clock.advance(2 * 3600)
        // Already out of what is shown, even before the file is tidied.
        #expect(store.records().map(\.values) == [line(2, at: start).values])
        store.write(line(3, at: clock.now))
        #expect(store.records().map(\.values) == [line(2, at: start).values, line(3, at: start).values])
        let text = try String(contentsOf: store.file, encoding: .utf8)
        #expect(!text.contains("n:1\n"))
    }

    @Test("Старое уходит из файла и тогда, когда новых строк больше нет")
    func ageWithoutNewLines() async throws {
        let folder = TempFolder()
        let clock = TestClock(start)
        var limits = AppLogStore.Limits()
        limits.tidyEvery = 0.05
        let store = makeStore(folder, clock: clock, limits: limits)
        store.write(line(1, at: start))
        store.flush()
        #expect(try String(contentsOf: store.file, encoding: .utf8).contains("n:1\n"))
        // A day and more of silence: the app has nothing to say, and nothing new is written.
        clock.advance(25 * 3600)
        #expect(await waitUntil { ((try? String(contentsOf: store.file, encoding: .utf8)) ?? "").isEmpty }, "строке больше суток, а она всё ещё в файле")
    }

    @Test("Серия переживает уборку файла со своим счётчиком")
    func tidyKeepsCount() {
        let folder = TempFolder()
        let clock = TestClock(start)
        var limits = AppLogStore.Limits()
        limits.tidyEvery = 3600
        let store = makeStore(folder, clock: clock, limits: limits)
        store.write(line(1, at: start))
        clock.advance(20 * 3600)
        for step in 0..<3 { store.write(LogRecord(at: clock.now.addingTimeInterval(Double(step)), message: .macWoke)) }
        store.flush()
        clock.advance(5 * 3600)
        store.write(line(2, at: clock.now))
        let records = store.records()
        #expect(records.first?.message == .macWoke)
        #expect(records.first?.count == 3)
    }

    @Test("Файл не перерастает предел и сохраняет самое новое")
    func cap() {
        let folder = TempFolder()
        var limits = AppLogStore.Limits()
        limits.maxBytes = 20_000
        limits.trimmedBytes = 16_000
        let store = makeStore(folder, limits: limits)
        for number in 0..<3000 {
            store.write(line(number, at: start.addingTimeInterval(Double(number))))
            if number % 100 == 0 {
                store.flush()
                #expect(size(store) <= limits.maxBytes)
            }
        }
        let records = store.records()
        #expect(size(store) <= limits.maxBytes)
        #expect(records.count > 100)
        #expect(records.last?.values.last == .number(2999))
        #expect(records.first?.values.last != .number(0))
        // The middle of the file came through whole.
        let numbers = records.compactMap { record in record.values.last.flatMap { value in Int(value.text) } }
        #expect(numbers == Array(numbers[0]...2999))
    }

    @Test("Счётчики повторов тоже не выводят файл за предел")
    func capWithCounts() {
        let folder = TempFolder()
        // All these lines are of one length, so the limit can be set to fall inside the fourth count, one byte before its end.
        let pair = LogFile.line(line(1000, at: start)).utf8.count + LogFile.repeatLine(at: start, extra: 1).utf8.count
        var limits = AppLogStore.Limits()
        limits.maxBytes = pair * 4 - 1
        limits.trimmedBytes = pair * 2
        let store = makeStore(folder, limits: limits)
        for number in 1000..<1004 {
            let at = start.addingTimeInterval(Double(number - 1000))
            store.write(line(number, at: at))
            store.write(line(number, at: at))
            store.flush()
            #expect(size(store) <= limits.maxBytes)
        }
        #expect(store.records().last?.values.last == .number(1003))
        #expect(store.records().last?.count == 2)
        #expect(!store.isBroken)
    }

    @Test("Зритель слышит, когда сохранение остановилось и когда вернулось")
    func viewerHearsSaving() async throws {
        let folder = TempFolder()
        let file = folder.url.appendingPathComponent("app.log")
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
        let clock = TestClock(start)
        let store = AppLogStore(file: file) { clock.now }
        let heard = Heard()
        _ = store.attach { heard.add($0) }
        store.write(line(1, at: clock.now))
        #expect(await waitUntil { heard.all == [.saving(false)] })
        try FileManager.default.removeItem(at: file)
        clock.advance(60)
        store.write(line(2, at: clock.now))
        #expect(await waitUntil { heard.all.count == 3 })
        #expect(heard.all.first == .saving(false))
        #expect(heard.all.contains(.saving(true)))
        #expect(!store.isBroken)
        store.detach()
    }

    @Test("Настоящие 5 МБ: файл не растёт дальше, чтение целого файла не занимает много времени")
    func fiveMegabytes() {
        let folder = TempFolder()
        let store = makeStore(folder)
        var written = 0
        var number = 0
        while written < 7 * 1024 * 1024 {
            let record = LogRecord(at: start.addingTimeInterval(Double(number) / 10), message: .requestEnded, values: [.tool("Bash"), .word(.allowed), .word(.hotKey), .seconds(4), .session("3f9a11c2")])
            written += LogFile.line(record).utf8.count
            store.write(record)
            // The same words twice in a row would fold into one line, so another line goes in between.
            store.write(LogRecord(at: start.addingTimeInterval(Double(number) / 10), message: .macWoke))
            written += 40
            number += 1
        }
        store.flush()
        #expect(size(store) <= 5 * 1024 * 1024)
        #expect(size(store) > 3 * 1024 * 1024)
        let began = Date()
        let records = store.records()
        let seconds = Date().timeIntervalSince(began)
        #expect(records.count > 30_000)
        #expect(seconds < 20, "прочитано за \(seconds) с")
    }

    @Test("Запись не держит того, кто пишет")
    func cheap() {
        let folder = TempFolder()
        let store = makeStore(folder)
        let began = Date()
        for number in 0..<10_000 { store.write(line(number, at: start)) }
        let seconds = Date().timeIntervalSince(began)
        store.flush()
        // A hundred microseconds a line even on a machine under load, and in a debug build.
        #expect(seconds < 1, "10000 строк за \(seconds) с")
    }

    @Test("Подмешанный мусор не мешает ни чтению, ни записи")
    func garbage() throws {
        let folder = TempFolder()
        let file = folder.url.appendingPathComponent("app.log")
        var junk = Data((0..<4096).map { UInt8($0 % 251) })
        junk.append(0x0A)
        junk.append(Data(LogFile.line(line(1, at: start)).utf8))
        try junk.write(to: file)
        let store = AppLogStore(file: file) { start }
        #expect(store.records().count == 1)
        store.write(line(2, at: start))
        #expect(store.records().count == 2)
    }

    @Test("Оборванная в падении строка не приклеивается к следующей")
    func tornLine() throws {
        let folder = TempFolder()
        let file = folder.url.appendingPathComponent("app.log")
        try Data((LogFile.line(line(1, at: start)) + "2026-11-06T11:02:11.123Z\tinfo\tapp\tapp").utf8).write(to: file)
        let store = AppLogStore(file: file) { start }
        store.write(line(2, at: start))
        #expect(store.records().map(\.values.last) == [.number(1), .number(2)])
    }

    @Test("Огромный файл не читается целиком и урезается при первой записи")
    func hugeFile() throws {
        let folder = TempFolder()
        let file = folder.url.appendingPathComponent("app.log")
        FileManager.default.createFile(atPath: file.path, contents: nil)
        let handle = try FileHandle(forWritingTo: file)
        let chunk = Data(repeating: 0x41, count: 1024 * 1024)
        for _ in 0..<40 { try handle.write(contentsOf: chunk) }
        try handle.write(contentsOf: Data("\n".utf8))
        try handle.write(contentsOf: Data(LogFile.line(line(1, at: start)).utf8))
        try handle.close()
        let store = AppLogStore(file: file) { start }
        #expect(store.records().count == 1)
        store.write(line(2, at: start))
        #expect(store.records().count == 2)
        #expect(((try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? .max) < 5 * 1024 * 1024)
    }

    @Test("Папка на месте файла: приложение живёт, журнал честно сломан")
    func folderInstead() throws {
        let folder = TempFolder()
        let file = folder.url.appendingPathComponent("app.log")
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
        let store = AppLogStore(file: file) { start }
        store.write(line(1, at: start))
        #expect(store.records().isEmpty)
        #expect(store.isBroken)
    }

    @Test("Нет места для папки: тоже ничего страшного")
    func noFolder() throws {
        let folder = TempFolder()
        let blocker = folder.write("file", "x")
        let store = AppLogStore(file: blocker.appendingPathComponent("logs/app.log")) { start }
        store.write(line(1, at: start))
        #expect(store.records().isEmpty)
        #expect(store.isBroken)
    }

    @Test("Журнал чинится сам, когда файл снова можно открыть")
    func recovers() throws {
        let folder = TempFolder()
        let file = folder.url.appendingPathComponent("app.log")
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
        let clock = TestClock(start)
        let store = AppLogStore(file: file) { clock.now }
        store.write(line(1, at: clock.now))
        #expect(store.isBroken)
        try FileManager.default.removeItem(at: file)
        clock.advance(60)
        store.write(line(2, at: clock.now))
        #expect(!store.isBroken)
        #expect(store.records().map(\.values.last) == [.number(2)])
    }

    @Test("Запись не идёт по чужой ссылке")
    func noLinks() throws {
        let folder = TempFolder()
        let other = folder.write("someone-elses-file", "важное\n")
        let file = folder.url.appendingPathComponent("app.log")
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: other)
        let store = AppLogStore(file: file) { start }
        store.write(line(1, at: start))
        store.flush()
        #expect(try String(contentsOf: other, encoding: .utf8) == "важное\n")
    }

    @Test("Файл убрали во время работы: новые строки идут в новый файл")
    func removedWhileRunning() throws {
        let folder = TempFolder()
        let clock = TestClock(start)
        let store = makeStore(folder, clock: clock)
        store.write(line(1, at: clock.now))
        store.flush()
        try FileManager.default.removeItem(at: store.file)
        clock.advance(2 * 3600)
        store.write(line(2, at: clock.now))
        #expect(store.records().map(\.values.last) == [.number(2)])
    }
}

@Suite("Журнал: кто что пишет")
struct AppLogSourcesTests {
    private let plan = HookInstaller.Plan(helperPath: "/invented/boris-hook", permissions: true, permissionWait: 600)

    @Test("Запись в настройки Claude: добавлено, копия, возврат исходного")
    func settingsWrites() throws {
        let folder = TempFolder()
        let file = folder.write("settings.json", #"{"theme":"secret-theme"}"# + "\n")
        let capture = ThreadCapture()
        defer { capture.stop() }
        try HookInstaller.install(at: file, plan: plan)
        #expect(capture.messages == [.claudeSettingsBackup, .claudeSettingsWritten])
        #expect(capture.records.last?.values == [.word(.hooksAdded)])
        try HookInstaller.uninstall(at: file)
        #expect(capture.records.last?.values == [.word(.originalRestored)])
    }

    @Test("Запись поверх чужих правок и удаление файла названы иначе")
    func otherWrites() throws {
        let folder = TempFolder()
        let file = folder.url.appendingPathComponent("settings.json")
        let capture = ThreadCapture()
        defer { capture.stop() }
        try HookInstaller.install(at: file, plan: plan)
        try HookInstaller.uninstall(at: file)
        #expect(capture.records.last?.values == [.word(.fileRemoved)])

        try HookInstaller.install(at: file, plan: plan)
        var settings = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any] ?? [:]
        settings["theme"] = "added-later"
        try JSONSerialization.data(withJSONObject: settings).write(to: file)
        try HookInstaller.uninstall(at: file)
        #expect(capture.records.last?.values == [.word(.hooksRemoved)])
    }

    @Test("Повреждённые настройки: предупреждение и ни слова из файла")
    func damagedSettings() {
        let folder = TempFolder()
        let file = folder.write("settings.json", "{ secret-text not json")
        let capture = ThreadCapture()
        defer { capture.stop() }
        #expect(throws: (any Error).self) { try HookInstaller.install(at: file, plan: plan) }
        #expect(capture.messages == [.claudeSettingsUnreadable])
    }

    @Test("Проверка статуса ничего не пишет: она идёт дважды в минуту")
    func statusIsQuiet() {
        let folder = TempFolder()
        let file = folder.write("settings.json", "{ secret-text not json")
        let capture = ThreadCapture()
        defer { capture.stop() }
        _ = HookInstaller.status(at: file, plan: plan)
        #expect(capture.messages.isEmpty)
    }

    @Test("Сводка наблюдателя: только перемены, а не каждый проход")
    func watch() {
        let capture = ThreadCapture()
        defer { capture.stop() }
        var watch = AppLogWatch()
        let began = start
        watch.started(now: began)
        func output(issues: Set<FormatIssue> = [], folder: Bool = true, tokens: Int = 0) -> WorkEngine.Output {
            WorkEngine.Output(at: began, model: WorkModel(), world: WorldSnapshot(takenAt: began, claudeFolderFound: folder, formatIssues: issues), tokensVersion: tokens)
        }
        watch.saw(output(), now: began.addingTimeInterval(2))
        #expect(capture.messages == [.firstRead])
        for _ in 0..<10 { watch.saw(output(), now: began.addingTimeInterval(3)) }
        #expect(capture.messages == [.firstRead])
        watch.saw(output(tokens: 1), now: began.addingTimeInterval(4))
        #expect(capture.messages == [.firstRead, .tokensCounted])
        let issue = FormatIssue.unknownJournalEvent("secret_event_name")
        watch.saw(output(issues: [issue, .unreadableFinal(runId: "wf_secret")]), now: began)
        watch.saw(output(issues: [issue]), now: began)
        watch.saw(output(), now: began)
        watch.saw(output(folder: false), now: began)
        watch.saw(output(), now: began)
        let lines = capture.records.map(\.message)
        #expect(lines.filter { $0 == .formatIssue }.count == 2)
        #expect(lines.filter { $0 == .formatFine }.count == 1)
        #expect(lines.suffix(2) == [.claudeFolderMissing, .claudeFolderFound])
        #expect(!capture.records.flatMap(\.values).map(\.stored).joined().contains("secret"))
    }

    @Test("Папка, найденная с первого взгляда, не достойна строки")
    func folderFromStart() {
        let capture = ThreadCapture()
        defer { capture.stop() }
        var watch = AppLogWatch()
        watch.saw(WorkEngine.Output(at: start, model: WorkModel(), world: WorldSnapshot(takenAt: start, claudeFolderFound: true)))
        #expect(capture.messages.isEmpty)
    }

    @Test("Диагностика с журналом остаётся чистой")
    func diagnostics() {
        let tail = [LogRecord(at: start, message: .hooksLost), LogRecord(at: start, message: .requestAsked, values: [.tool("mcp__secret_server__run"), .session("3f9a11c2-secret-part")])]
        let report = Diagnostics.adding(log: tail, to: "Boris 1.0")
        #expect(report.hasPrefix("Boris 1.0\n\nLog:\n"))
        #expect(report.contains("3f9a11c2"))
        #expect(!report.contains("secret"))
        #expect(Diagnostics.adding(log: [], to: "Boris 1.0") == "Boris 1.0")
    }
}

/// Sends whatever comes back from the real hook server through it, with invented secrets in every field.
@Suite("Журнал: сервер хуков", .serialized)
struct AppLogServerTests {
    private func send(_ text: String, to path: String) {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        defer { close(fd) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: Array(path.utf8)) }
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else { return }
        var bytes = Array(text.utf8)
        _ = write(fd, &bytes, bytes.count)
    }

    @Test("Нечитаемое сообщение от хука попадает в журнал без своего содержимого")
    func unreadable() async {
        let folder = TempFolder()
        let store = AppLogStore(file: folder.url.appendingPathComponent("app.log"))
        AppLog.add(store)
        defer { AppLog.remove(store) }
        let path = NSTemporaryDirectory() + "l\(UUID().uuidString.prefix(8)).sock"
        let server = HookServer(path: path)
        #expect(server.start())
        defer { server.stop() }
        send("this is not json, secret-hook-text\n", to: path)
        #expect(await waitUntil { store.records().contains { $0.message == .hookMessageUnreadable } })
        store.flush()
        let raw = (try? String(contentsOf: store.file, encoding: .utf8)) ?? ""
        #expect(!raw.contains("secret-hook-text"))
    }
}
