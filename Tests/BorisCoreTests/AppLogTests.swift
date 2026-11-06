import Foundation
import Testing
@testable import BorisCore

/// Hears what is noted while it lives. Other tests run at the same time, so a check can ask for its own thread only: everything in one synchronous stretch of a test stays on one thread.
private final class LogCapture: LogSink, @unchecked Sendable {
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

    var records: [LogRecord] { lock.withLock { heard } }
}

private struct Failure: Error {
    var secret = "/Users/someone/private-project/notes.txt"
}

@Suite("Журнал: значения в строке")
struct LogValueTests {
    @Test("Свои инструменты названы, а чужие имена не проходят")
    func tools() {
        #expect(LogValue.tool("Bash").text == "Bash")
        #expect(LogValue.tool("AskUserQuestion").text == "AskUserQuestion")
        #expect(LogValue.tool("mcp__acme-internal__deploy").text == "mcp")
        #expect(LogValue.tool("SecretProjectName").text == "other")
        #expect(LogValue.tool("rm -rf /Users/someone").text == "other")
        #expect(LogValue.tool("").text == "other")
    }

    @Test("От сессии остаётся начало, а то, что не похоже на идентификатор, не проходит")
    func sessions() {
        #expect(LogValue.session("3f9a11c2-77aa-4c55-8e21-000000000000").text == "3f9a11c2")
        #expect(LogValue.session("abc").text == "abc")
        #expect(LogValue.session("").text == "?")
        #expect(LogValue.session("/Users/someone/project").text == "?")
        #expect(LogValue.session("секретный проект").text == "?")
    }

    @Test("От ошибки остаётся домен и номер, но не описание с путём")
    func failures() {
        let cocoa = NSError(domain: NSCocoaErrorDomain, code: 513, userInfo: [NSFilePathErrorKey: "/Users/someone/private-project", NSLocalizedDescriptionKey: "You can't save /Users/someone/private-project"])
        #expect(LogValue.failure(cocoa).text == "NSCocoaErrorDomain/513")
        let own = LogValue.failure(Failure())
        #expect(!own.text.contains("private"))
        #expect(!own.text.contains("someone"))
        let odd = NSError(domain: "/Users/someone has spaces", code: 1)
        #expect(LogValue.failure(odd).text == "other/1")
    }

    @Test("Версия и клавиши не могут нести постороннего")
    func versionAndKeys() {
        #expect(LogValue.version("0.4.1-beta.2+77").text == "0.4.1-beta.2+77")
        #expect(LogValue.version("/Users/someone").text == "?")
        #expect(LogValue.version("my secret").text == "?")
        #expect(LogValue.keys("⌥⌘O").text == "⌥⌘O")
        #expect(!LogValue.keys("⌥⌘ ").text.contains(" "))
        #expect(LogValue.keys("a very long text that someone typed").text.count <= 16)
        #expect(LogValue.keys("").text == "?")
    }

    @Test("Значение возвращается из файла таким же", arguments: [
        LogValue.number(12), .number(-3), .decimal(0.6), .seconds(1.25), .flag(true), .flag(false), .word(.connectSheet), .choice(WalrusSound.done),
        .tool("Bash"), .tool("mcp__x__y"), .session("3f9a11c2-77aa"), .version("0.4.1"), .failure(CocoaError(.fileWriteOutOfSpace)), .keys("⌥⌘O"),
    ])
    func storedRoundTrip(value: LogValue) {
        #expect(LogValue(stored: value.stored) == value)
    }

    @Test("Подправленный файл не вставит слова в то, что копируют", arguments: [
        "w:Какой-то текст", "w:connectSheet ", "c:has space", "c:/Users/someone", "t:SecretProjectName", "i:/Users/x", "i:123456789", "e:a b/1", "e:domain", "n:abc", "s:nan", "f:maybe", "v:my secret", "k:", "k:a b", "x:1", "нет двоеточия",
    ])
    func tampered(stored: String) {
        #expect(LogValue(stored: stored) == nil)
    }

    @Test("Длительность читается в секундах, минутах или часах")
    func durations() {
        // The separator follows the language, which another test in this process may have set.
        #expect(["0.8 s", "0,8 s"].contains(LogValue.seconds(0.84).shown))
        #expect(LogValue.seconds(31).shown == "31 s")
        #expect(LogValue.seconds(600).shown == "10 min")
        #expect(LogValue.seconds(4 * 3600).shown == "4 h")
    }
}

@Suite("Журнал: файл")
struct LogFileTests {
    private let moment = Date(timeIntervalSince1970: 1_793_880_000.25)

    @Test("Запись переживает файл")
    func roundTrip() {
        let record = LogRecord(at: moment, message: .requestEnded, values: [.tool("Bash"), .word(.allowed), .word(.hotKey), .seconds(1.5), .session("abcd1234")])
        let parsed = LogFile.parse(Data(LogFile.line(record).utf8))
        #expect(parsed == [record])
    }

    @Test("Строка читается глазами: время, уровень, область, ключ")
    func readable() {
        let line = LogFile.line(LogRecord(at: moment, message: .hooksLost))
        let fields = line.dropLast().split(separator: "\t").map(String.init)
        #expect(fields == [LogFile.stamp(moment), "warning", "hooks", "hooksLost"])
        #expect(line.hasSuffix("\n"))
    }

    @Test("Время в файле точно до тысячных, в том числе в високосный день")
    func stamps() {
        for interval in [0.0, 1_709_164_800.5, 1_709_251_199.999, 1_793_880_000.25, 4_102_444_799.001] {
            let date = Date(timeIntervalSince1970: interval)
            let parsed = LogFile.parse(Data(LogFile.line(LogRecord(at: date, message: .appQuit)).utf8))
            #expect(abs((parsed.first?.at.timeIntervalSince1970 ?? -1) - interval) < 0.002)
        }
    }

    @Test("Строка с плюсом добавляет повторы к предыдущей")
    func repeats() {
        let first = LogRecord(at: moment, message: .soundPlayed, values: [.choice(WalrusSound.alarm)])
        let later = moment.addingTimeInterval(30)
        let text = LogFile.line(first) + LogFile.repeatLine(at: later, extra: 2) + LogFile.repeatLine(at: later.addingTimeInterval(5), extra: 1)
        let parsed = LogFile.parse(Data(text.utf8))
        #expect(parsed.count == 1)
        #expect(parsed.first?.count == 4)
        #expect(parsed.first?.lastAt == later.addingTimeInterval(5))

        var folded = first
        folded.count = 4
        folded.lastAt = later.addingTimeInterval(5)
        #expect(LogFile.parse(Data(LogFile.lines(folded).utf8)) == [folded])
    }

    @Test("Испорченные строки выпадают, а целые остаются")
    func damaged() {
        let good = LogRecord(at: moment, message: .appQuit)
        var data = Data()
        data.append(Data("ни к чему не относящийся текст\n".utf8))
        data.append(Data("\(LogFile.stamp(moment))\t+\t3\n".utf8)) // a repeat of nothing
        data.append(Data([0xFF, 0xFE, 0x00, 0x01, 0x0A]))
        data.append(Data("\(LogFile.stamp(moment))\tinfo\tapp\tnoSuchMessage\n".utf8))
        data.append(Data("\(LogFile.stamp(moment))\tinfo\tsound\tsoundPlayed\tw:My secret text\n".utf8))
        data.append(Data("2026-13-45T99:99:99.000Z\tinfo\tapp\tappQuit\n".utf8))
        data.append(Data(LogFile.line(good).utf8))
        data.append(Data("\(LogFile.stamp(moment))\t+\tmany\n".utf8))
        data.append(Data("\n\n\t\t\n".utf8))
        // The last line has no end: a crash in the middle of writing it.
        data.append(Data("\(LogFile.stamp(moment))\tinfo\tapp\tappSta".utf8))
        #expect(LogFile.parse(data) == [good])
    }

    @Test("Счётчик испорченной строки не достаётся её соседке")
    func countOfDamagedLine() {
        let good = LogRecord(at: moment, message: .appQuit)
        var data = Data(LogFile.line(good).utf8)
        data.append(Data("\(LogFile.stamp(moment))\tinfo\tapp\tnoSuchMessage\n".utf8))
        data.append(Data("\(LogFile.stamp(moment))\t+\t3\n".utf8))
        #expect(LogFile.parse(data) == [good])

        // Two counts in a row are one series, as after a flush in the middle of it.
        var series = Data(LogFile.line(good).utf8)
        series.append(Data(LogFile.repeatLine(at: moment, extra: 2).utf8))
        series.append(Data(LogFile.repeatLine(at: moment, extra: 3).utf8))
        #expect(LogFile.parse(series).first?.count == 6)
    }

    @Test("Пустой файл даёт пустой журнал")
    func empty() {
        #expect(LogFile.parse(Data()).isEmpty)
    }
}

@Suite("Журнал: что написано в строках")
struct LogTextTests {
    @Test("Каждое сообщение заполняется, сколько бы значений ни пришло", arguments: LogMessage.allCases)
    func fills(message: LogMessage) {
        let none = LogRecord(message: message).text
        #expect(!none.isEmpty)
        #expect(!none.contains("%@"))
        let many = LogRecord(message: message, values: Array(repeating: .number(1), count: 9)).text
        #expect(!many.contains("%@"))
    }

    @Test("У каждого сообщения своя запись в файле")
    func keysAreUnique() {
        #expect(Set(LogMessage.allCases.map(\.rawValue)).count == LogMessage.allCases.count)
    }

    @Test("Слова переведены, а сообщения об ошибках не прячутся на уровне «инфо»")
    func levels() {
        for failure in [LogMessage.hookServerFailed, .fileWriteFailed, .soundFailed, .bannerFailed, .keychainFailed] { #expect(failure.level == .error) }
        for warning in [LogMessage.hooksLost, .telegramFailed, .formatIssue, .hotKeyTaken] { #expect(warning.level == .warning) }
        for word in LogWord.allCases { #expect(!word.label.isEmpty) }
    }

    @Test("Повторы и время их конца видны в строке")
    func repeated() {
        var record = LogRecord(at: Date(timeIntervalSince1970: 1_793_880_000), message: .soundPlayed, values: [.choice(WalrusSound.alarm)])
        record.count = 5
        record.lastAt = record.at.addingTimeInterval(90)
        var renderer = LogRenderer()
        let row = renderer.row(record)
        #expect(row.text.hasPrefix("Played: alarm ×5, until "))
        #expect(row.plain.contains(" info sound: Played: alarm ×5"))
    }

    @Test("Период и фильтр отбирают строки")
    func arranging() {
        let now = Date()
        var renderer = LogRenderer()
        func row(_ ago: TimeInterval, _ message: LogMessage) -> LogRow {
            renderer.row(LogRecord(at: now.addingTimeInterval(-ago), message: message))
        }
        let rows = [row(7200, .appQuit), row(1800, .hooksLost), row(60, .appStarted), row(30, .hookServerFailed)]
        let texts = { (shown: [LogRow]) in shown.filter { !$0.isDay }.map(\.level) }
        #expect(texts(LogView.arrange(rows, period: .everything, onlyProblems: false, now: now)) == [.info, .warning, .info, .error])
        #expect(texts(LogView.arrange(rows, period: .everything, onlyProblems: true, now: now)) == [.warning, .error])
        #expect(LogView.arrange(rows, period: .lastHour, onlyProblems: false, now: now).filter { !$0.isDay }.count == 3)
    }

    @Test("Серия, которая ещё шла в последний час, остаётся в нём")
    func seriesInHour() {
        let now = Date()
        var record = LogRecord(at: now.addingTimeInterval(-7200), message: .soundPlayed, values: [.choice(WalrusSound.done)])
        record.count = 40
        record.lastAt = now.addingTimeInterval(-60)
        var renderer = LogRenderer()
        #expect(LogView.arrange([renderer.row(record)], period: .lastHour, onlyProblems: false, now: now).contains { !$0.isDay })
    }

    @Test("Где меняется день, стоит заголовок")
    func dayHeadings() {
        let now = Date()
        var renderer = LogRenderer()
        // Two days back, so that no change of clocks can make it the same day.
        let earlier = renderer.row(LogRecord(at: now.addingTimeInterval(-2 * 86400), message: .appStarted))
        let today = renderer.row(LogRecord(at: now, message: .appQuit))
        let shown = LogView.arrange([earlier, today], period: .everything, onlyProblems: false, now: now)
        #expect(shown.map(\.isDay) == [true, false, true, false])
        #expect(LogView.arrange([today], period: .everything, onlyProblems: false, now: now).map(\.isDay) == [false])
    }

    @Test("Новая строка попадает в показанное, только если проходит фильтр")
    func appending() {
        var renderer = LogRenderer()
        let now = Date()
        var shown: [LogRow] = []
        LogView.append(renderer.row(LogRecord(at: now, message: .appQuit)), to: &shown, onlyProblems: true)
        #expect(shown.isEmpty)
        LogView.append(renderer.row(LogRecord(at: now, message: .hooksLost)), to: &shown, onlyProblems: true)
        #expect(shown.count == 1)
        LogView.append(renderer.row(LogRecord(at: now.addingTimeInterval(86400), message: .hooksLost)), to: &shown, onlyProblems: true)
        #expect(shown.map(\.isDay) == [false, true, false])
    }

    @Test("В скопированном есть заголовок и каждая показанная строка")
    func copying() {
        var renderer = LogRenderer()
        let rows = [renderer.row(LogRecord(at: Date(), message: .hooksLost))]
        let text = LogView.copyText(rows, period: .lastHour, now: Date())
        #expect(text.contains("Boris log, last hour, lines: 1"))
        #expect(text.contains("warning hooks: Removed or changed by something else"))
        #expect(text.hasSuffix("\n"))
    }

    @Test("Высота строки считается без замеров", arguments: [
        ("short", 80, 1),
        ("", 80, 1),
        ("one two three", 7, 2),
        ("one two six", 3, 3),
        ("one two three", 3, 4),
        ("aaaa bbbb", 4, 2),
        ("aaaaaaaaaa", 4, 3),
        ("aaaaaaaa", 4, 2),
        ("aa aaaaaaaaaa b", 4, 4),
    ])
    func wrapping(text: String, perLine: Int, lines: Int) {
        #expect(LogView.lines(of: text, perLine: perLine) == lines)
    }
}

@Suite("Журнал: панель", .serialized)
struct PanelLogTests {
    private let start = Date(timeIntervalSince1970: 1_793_880_000)

    @Test("Указатель, проходящий мимо, ничего не пишет")
    func passingBy() {
        let capture = LogCapture()
        defer { capture.stop() }
        var track = PanelLogTrack()
        track.note(isOpen: true, hovering: true, now: start)
        track.note(isOpen: true, hovering: true, now: start.addingTimeInterval(0.5))
        track.note(isOpen: false, hovering: false, now: start.addingTimeInterval(1))
        #expect(capture.records.isEmpty)
    }

    @Test("Панель, открытая указателем надолго, даёт одну строку при закрытии")
    func pointerStayed() {
        let capture = LogCapture()
        defer { capture.stop() }
        var track = PanelLogTrack()
        track.note(isOpen: true, hovering: true, now: start)
        track.note(isOpen: false, hovering: false, now: start.addingTimeInterval(12))
        #expect(capture.records.map(\.message) == [.panelClosed])
        #expect(capture.records.first?.values.last == .word(.byPointer))
    }

    @Test("Запрос пишет и открытие, и закрытие")
    func request() {
        let capture = LogCapture()
        defer { capture.stop() }
        var track = PanelLogTrack()
        track.note(isOpen: true, hovering: false, now: start)
        track.note(isOpen: false, hovering: false, now: start.addingTimeInterval(1))
        #expect(capture.records.map(\.message) == [.panelOpened, .panelClosed])
    }
}

@MainActor
@Suite("Журнал: настройки", .serialized)
struct SettingsLogTests {
    private enum Choice: Equatable {
        case plain
        case withPayload(name: String)
    }

    private enum Key: Hashable {
        case first, second
    }

    private struct Sample: Equatable {
        var on = true
        var count = 3
        var volume = 0.6
        var secret = "токен-который-нельзя-показывать"
        var telegramChat = "@secret_chat"
        var userBirthday = MonthDay(month: 3, day: 14)
        var maybe: String? = "/Users/someone/private-project"
        var choice = Choice.withPayload(name: "Studio Monitor")
        var byKey: [Key: Bool] = [.first: true]
        var list = ["/Users/someone/private-project"]
    }

    private func field(_ fields: [SettingsLog.Field], _ path: String) -> SettingsLog.Field? {
        fields.first { $0.path == path }
    }

    @Test("Числа и переключатели названы, строки и содержимое перечислений скрыты")
    func fields() {
        let fields = SettingsLog.fields(of: Sample(), at: "sample")
        #expect(field(fields, "sample.on")?.value == .flag(true))
        #expect(field(fields, "sample.count")?.value == .number(3))
        #expect(field(fields, "sample.volume")?.value == .decimal(0.6))
        #expect(field(fields, "sample.byKey.first")?.value == .flag(true))
        #expect(field(fields, "sample.secret")?.value == nil)
        #expect(field(fields, "sample.telegramChat")?.value == nil)
        #expect(field(fields, "sample.userBirthday")?.value == nil)
        #expect(field(fields, "sample.maybe")?.value == nil)
        #expect(field(fields, "sample.list")?.value == nil)
        let spoken = fields.compactMap(\.value).map(\.stored).joined(separator: " ")
        #expect(spoken.contains("withPayload"))
        for hidden in ["токен", "secret_chat", "Studio", "someone", "14"] { #expect(!spoken.contains(hidden)) }
    }

    @Test("Движение ползунка даёт одну строку с тем, где он остановился")
    func slider() {
        let capture = LogCapture()
        defer { capture.stop() }
        for step in 0..<40 { SettingsLog.changed("sliderForTest", from: Double(step) / 100, to: Double(step + 1) / 100) }
        SettingsLog.flush()
        let lines = capture.records.filter { $0.values.first?.text == "sliderForTest" }
        #expect(lines.count == 1)
        #expect(lines.first?.message == .settingChanged)
        #expect(lines.first?.values.last == .decimal(0.40))
    }

    @Test("Вернулось к прежнему: писать нечего")
    func backToStart() {
        let capture = LogCapture()
        defer { capture.stop() }
        SettingsLog.changed("backForTest", from: 1, to: 2)
        SettingsLog.changed("backForTest", from: 2, to: 1)
        SettingsLog.flush()
        #expect(!capture.records.contains { $0.values.first?.text == "backForTest" })
    }

    @Test("Секретное поле: только то, что оно изменилось")
    func secretField() {
        let capture = LogCapture()
        defer { capture.stop() }
        var after = Sample()
        after.telegramChat = "@other_secret"
        after.count = 4
        SettingsLog.changed("sampleForTest", from: Sample(), to: after)
        SettingsLog.flush()
        let lines = capture.records.filter { $0.values.first?.text.hasPrefix("sampleForTest") == true }
        #expect(lines.count == 2)
        let chat = lines.first { $0.values.first?.text == "sampleForTest.telegramChat" }
        #expect(chat?.message == .settingChangedHidden)
        #expect(chat?.values.count == 1)
        #expect(lines.first { $0.values.first?.text == "sampleForTest.count" }?.values.last == .number(4))
    }

    @Test("Ни одна строка не появляется, пока журнал не подключён")
    func nothingInstalled() {
        // With a sink of another test around this can only say that a change of nothing writes nothing.
        let capture = LogCapture()
        defer { capture.stop() }
        SettingsLog.changed("sameForTest", from: 5, to: 5)
        SettingsLog.flush()
        #expect(!capture.records.contains { $0.values.first?.text == "sameForTest" })
    }
}

/// Every call in the app, read from its source: a line cannot go wrong only on a path a test happens not to take.
@Suite("Журнал: все вызовы в коде")
struct LogCallsTests {
    private struct Call {
        var file: String
        var messages: [LogMessage]
        var values: [String]
    }

    private static let sources: [(name: String, text: String)] = {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources")
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
        return files.compactMap { url in (try? String(contentsOf: url, encoding: .utf8)).map { (url.lastPathComponent, $0) } }
    }()

    private static let calls: [Call] = sources.flatMap { source -> [Call] in
        var calls: [Call] = []
        var rest = source.text[...]
        while let start = rest.range(of: "AppLog.note(") {
            var depth = 1
            var inString = false
            var arguments: [String] = [""]
            var index = start.upperBound
            while index < rest.endIndex, depth > 0 {
                let character = rest[index]
                if character == "\"" { inString.toggle() }
                if !inString {
                    if "([{".contains(character) { depth += 1 }
                    if ")]}".contains(character) { depth -= 1 }
                }
                if depth > 0 {
                    if depth == 1, character == ",", !inString { arguments.append("") } else { arguments[arguments.count - 1].append(character) }
                }
                index = rest.index(after: index)
            }
            rest = rest[index...]
            let first = arguments[0]
            let names = first.split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "." }).filter { $0.hasPrefix(".") }.map { String($0.dropFirst()) }
            let messages = names.compactMap(LogMessage.init(rawValue:))
            calls.append(Call(file: source.name, messages: messages, values: arguments.dropFirst().map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }))
        }
        return calls
    }

    @Test("Вызовы найдены")
    func found() {
        #expect(Self.calls.count > 60)
        #expect(Self.calls.allSatisfy { !$0.messages.isEmpty })
    }

    @Test("Значений у вызова столько, сколько мест в сообщении")
    func valueCounts() {
        for call in Self.calls {
            for message in call.messages {
                let places = message.template.components(separatedBy: "%@").count - 1
                #expect(places == call.values.count, "\(message.rawValue) в \(call.file)")
            }
        }
    }

    @Test("Каждое сообщение где-то пишется, а значит, у словаря нет мёртвых записей")
    func everyMessageIsUsed() {
        let used = Set(Self.calls.flatMap(\.messages))
        for message in LogMessage.allCases { #expect(used.contains(message), "\(message.rawValue) нигде не пишется") }
    }

    @Test("В вызов нельзя передать свой текст: нет строк и подстановок")
    func noFreeText() {
        for call in Self.calls {
            for value in call.values {
                #expect(!value.contains("\\("), "подстановка в \(call.file): \(value)")
                let literals = value.components(separatedBy: "\"").enumerated().filter { $0.offset % 2 == 1 }.map(\.element)
                let hasText = literals.contains { !$0.isEmpty }
                #expect(!hasText, "строка в \(call.file): \(value)")
            }
        }
    }

    @Test("Значения идут только через двери, которые их проверяют")
    func onlyCheckedDoors() {
        let doors = [".number(", ".decimal(", ".seconds(", ".flag(", ".word(", ".choice(", ".tool(", ".session(", ".version(", ".failure(", ".keys("]
        let others = ["about", "banner.about", "summary.about", "line.about", "name", "value"]
        for call in Self.calls {
            for value in call.values {
                #expect(doors.contains { value.hasPrefix($0) } || others.contains(value), "\(call.file): \(value)")
            }
        }
    }

    @Test("Логи Claude и текст запроса не попадают в значения")
    func nothingFromTheRequest() {
        let forbidden = [".command", ".cwd", ".project", ".content", ".reason", ".title", ".body", ".text", ".subject", ".full", ".telegramChat", ".token)", "(token", "(chat", ".chat", "localizedDescription", "String(describing"]
        for call in Self.calls {
            for value in call.values {
                #expect(!forbidden.contains { value.contains($0) }, "\(call.file): \(value)")
            }
        }
    }
}
