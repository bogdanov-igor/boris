import Foundation
import Testing
@testable import BorisCore

@Suite("Настройки источников")
struct SourceSettingsTests {
    @Test("При первом запуске включено всё, кроме чата, и снимки разрешены")
    func firstLaunch() {
        let settings = SourceSettings()
        for source in SourceID.allCases {
            #expect(settings.reads(source) == (source != .chat), "\(source)")
            #expect(settings[source].capture)
        }
        #expect(settings.isOn(.claudeCode))
        #expect(settings.isOn(.cowork))
        #expect(!settings.isOn(.chat))
        #expect(settings.captureForbidden.isEmpty)
    }

    @Test("Список источников как на макете: шесть сред Claude Code, Cowork и чат")
    func theList() {
        #expect(SourceProduct.claudeCode.sources == [.terminal, .vsCode, .cursor, .claudeDesktop, .remote, .program])
        #expect(SourceProduct.cowork.sources == [.cowork])
        #expect(SourceProduct.chat.sources == [.chat])
    }

    @Test("Выключение продукта гасит все его среды, но не трогает другие продукты, а включение возвращает выбор")
    func wholeProduct() {
        var settings = SourceSettings()
        settings[.cursor].read = false
        settings.set(.claudeCode, on: false)
        for source in SourceProduct.claudeCode.sources { #expect(!settings.reads(source)) }
        #expect(settings.reads(.cowork))
        settings.set(.claudeCode, on: true)
        #expect(settings.reads(.terminal))
        #expect(!settings.reads(.cursor), "свой выбор для Cursor остался")
    }

    @Test("Чат включается своим продуктом, и ответов в нём всё равно нет")
    func chat() {
        var settings = SourceSettings()
        settings.set(.chat, on: true)
        #expect(settings.reads(.chat))
        #expect(!settings.answers(.chat))
        #expect(!settings.answers(.cowork))
        #expect(settings.answers(.terminal))
        #expect(SourceSettings().allOff == false)
    }

    @Test("Выключено считывание: нечего уведомлять и не на что отвечать")
    func readingOffTakesTheRest() {
        var settings = SourceSettings()
        settings[.vsCode].read = false
        #expect(!settings.notifies(.vsCode))
        #expect(!settings.answers(.vsCode))
        #expect(settings.notifies(.terminal))
    }

    @Test("Уведомления и ответы выключаются отдельно от считывания")
    func separateSwitches() {
        var settings = SourceSettings()
        settings[.terminal].notify = false
        settings[.vsCode].answer = false
        #expect(settings.reads(.terminal))
        #expect(!settings.notifies(.terminal))
        #expect(settings.answers(.terminal))
        #expect(settings.reads(.vsCode))
        #expect(settings.notifies(.vsCode))
        #expect(!settings.answers(.vsCode))
    }

    @Test("Работа неизвестно откуда не молчит и не теряет ответы")
    func unknownSource() {
        var settings = SourceSettings()
        for source in SourceID.allCases { settings[source].notify = false }
        #expect(settings.notifies(nil))
        #expect(settings.answers(nil))
    }

    @Test("Выбор переживает кодирование")
    func roundTrip() throws {
        var settings = SourceSettings()
        settings[.cursor] = SourceSwitches(read: false, notify: false, answer: true, capture: false)
        settings.set(.chat, on: true)
        settings.set(.cowork, on: false)
        let data = try JSONEncoder().encode(settings)
        #expect(try JSONDecoder().decode(SourceSettings.self, from: data) == settings)
    }

    @Test("Сохранённое другой версией не стоит человеку его выбора")
    func otherVersion() throws {
        let saved = #"{"productsOff":["cowork","something-new"],"switches":{"cursor":{"read":false,"mystery":1},"future":{"read":false},"vsCode":{"notify":"oops"}}}"#
        let settings = try JSONDecoder().decode(SourceSettings.self, from: Data(saved.utf8))
        #expect(!settings.isOn(.cowork))
        #expect(settings.isOn(.chat), "список продуктов прочитан как сохранён")
        #expect(!settings.reads(.cursor))
        #expect(settings[.cursor].notify, "поля, которых не было, принимают обычное значение")
        #expect(settings[.vsCode].notify, "непонятное значение не считается выключением")
        let empty = try JSONDecoder().decode(SourceSettings.self, from: Data("{}".utf8))
        #expect(empty == SourceSettings())
    }

    @Test("Запись без единого понятного поля не ломает настройку")
    func garbage() throws {
        let saved = #"{"productsOff":7,"switches":"none"}"#
        #expect(try JSONDecoder().decode(SourceSettings.self, from: Data(saved.utf8)) == SourceSettings())
    }
}

@Suite("Определение источника")
struct SourceDetectionTests {
    @Test("Откуда работа, по тому, что пишет Claude", arguments: [
        ("cli", SourceID?.some(.terminal)),
        ("claude-vscode", .vsCode),
        ("claude-cursor", .cursor),
        ("claude-desktop", .claudeDesktop),
        ("local-agent", .cowork),
        ("local_agent", .cowork),
        ("sdk-ts", .program),
        ("sdk-py", .program),
        ("sdk-cli", .program),
        ("something-new", nil),
    ])
    func entrypoints(entrypoint: String, source: SourceID?) {
        #expect(SourceID(entrypoint: entrypoint) == source)
    }

    @Test("Среды складываются в те же источники, что на экране")
    func environments() {
        #expect(SourceID(WorkEnvironment.insideClaude) == .terminal)
        #expect(SourceID(WorkEnvironment.remote(host: "build")) == .remote)
        #expect(SourceID(WorkEnvironment.chat) == .chat)
        #expect(SourceID(nil as WorkEnvironment?) == nil)
    }

    private let vsCodeLine = [
        "/Users/x/.vscode/extensions/anthropic.claude-code-2.0.0-darwin-arm64/resources/native-binary/claude",
        "/Applications/Visual Studio Code.app/Contents/Frameworks/Code Helper (Plugin).app/Contents/MacOS/Code Helper (Plugin)",
        "/Applications/Visual Studio Code.app/Contents/MacOS/Electron",
    ]
    private let cursorLine = [
        "/Users/x/.cursor/extensions/anthropic.claude-code-2.0.0-darwin-arm64/resources/native-binary/claude",
        "/Applications/Cursor.app/Contents/Frameworks/Cursor Helper (Plugin).app/Contents/MacOS/Cursor Helper (Plugin)",
        "/Applications/Cursor.app/Contents/MacOS/Cursor",
    ]

    @Test("Редактор виден по процессам: и по самому расширению, и по приложению над ним")
    func editorFromProcesses() {
        #expect(SourceDetection.editor(inPaths: vsCodeLine) == .vsCode)
        #expect(SourceDetection.editor(inPaths: cursorLine) == .cursor)
        #expect(SourceDetection.editor(inPaths: Array(cursorLine.dropFirst())) == .cursor)
        #expect(SourceDetection.editor(inPaths: ["/usr/local/bin/claude", "/bin/zsh", "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal"]) == nil)
    }

    @Test("Ближайший редактор решает: Cursor, запущенный из терминала VS Code, остаётся Cursor")
    func nearestEditor() {
        #expect(SourceDetection.editor(inPaths: Array(cursorLine.dropFirst()) + vsCodeLine) == .cursor)
    }

    @Test("Расширение сообщает одно и то же слово, и только процессы отличают Cursor от VS Code")
    func sameWordTwoEditors() {
        #expect(SourceDetection.source(entrypoint: "claude-vscode") { .cursor } == .cursor)
        #expect(SourceDetection.source(entrypoint: "claude-vscode") { .vsCode } == .vsCode)
        #expect(SourceDetection.source(entrypoint: "claude-vscode") { nil } == .vsCode)
    }

    @Test("Терминал внутри редактора остаётся терминалом, и процессы о нём не спрашивают")
    func terminalInsideAnEditor() {
        #expect(SourceDetection.source(entrypoint: "cli") {
            Issue.record("нечего уточнять")
            return .cursor
        } == .terminal)
        #expect(SourceDetection.source(entrypoint: nil) { .cursor } == nil)
    }

    @Test("Настоящая линия процессов идёт от самого процесса вверх, через его родителей")
    func realProcessLine() {
        let line = SourceDetection.linePaths(from: ProcessInfo.processInfo.processIdentifier)
        #expect(line.count >= 2, "тест запущен кем-то, и тот виден")
        #expect(line.first == Bundle.main.executablePath || line.first?.hasSuffix("xctest") == true || line.first?.contains("swiftpm-testing-helper") == true)
        #expect(SourceDetection.editor(of: 1) == nil)
        #expect(SourceDetection.editor(of: 999_999) == nil)
    }
}

@Suite("Начало журнала")
struct TranscriptHeadTests {
    private func file(_ text: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("boris-head-\(UUID().uuidString).jsonl")
        try text.write(to: url, atomically: false, encoding: .utf8)
        return url
    }

    @Test("Находит слово и читает только начало файла, сколько бы в нём ни было")
    func onlyTheStart() throws {
        let url = try file(#"{"type":"user","entrypoint":"claude-vscode","message":{}}"# + "\n" + String(repeating: "x", count: 4 * 1024 * 1024))
        defer { try? FileManager.default.removeItem(at: url) }
        let head = TranscriptHead.entrypoint(in: url)
        #expect(head.entrypoint == "claude-vscode")
        #expect(head.bytesRead <= 16 * 1024)
    }

    @Test("Слово на границе двух кусков всё равно находится")
    func acrossChunks() throws {
        let padding = String(repeating: "y", count: 16 * 1024 - 5)
        let url = try file(#"{"note":"\#(padding)","entrypoint":"cli"}"#)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(TranscriptHead.entrypoint(in: url).entrypoint == "cli")
    }

    @Test("То же слово в тексте запроса не принимается за поле: там его кавычки экранированы")
    func notFromText() throws {
        let url = try file(#"{"type":"user","message":{"content":"напиши \"entrypoint\":\"cli\" в файл"},"entrypoint":"claude-desktop"}"#)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(TranscriptHead.entrypoint(in: url).entrypoint == "claude-desktop")
    }

    @Test("Без слова поиск кончается на пределе, а не на конце большого файла")
    func gaveUp() throws {
        let url = try file(String(repeating: "z", count: 2 * 1024 * 1024))
        defer { try? FileManager.default.removeItem(at: url) }
        let head = TranscriptHead.entrypoint(in: url)
        #expect(head.entrypoint == nil)
        #expect(head.bytesRead <= 256 * 1024 + 16 * 1024)
    }

    @Test("Файла нет: ответа нет, и ничего не падает")
    func noFile() {
        let head = TranscriptHead.entrypoint(in: URL(fileURLWithPath: "/nonexistent/file.jsonl"))
        #expect(head.entrypoint == nil)
        #expect(head.bytesRead == 0)
    }
}

@Suite("Что решает посредник")
struct HookPolicyTests {
    @Test("Считывание выключено: посредник уходит, ничего не отправляя")
    func silent() {
        let policy = HookPolicy(silent: [.cursor])
        #expect(policy.action(for: .cursor, asking: true) == .leave)
        #expect(policy.action(for: .cursor, asking: false) == .leave)
        #expect(policy.action(for: .vsCode, asking: true) == .ask)
    }

    @Test("Ответы выключены: Boris только узнаёт, что сессия ждёт, а Claude не ждёт")
    func noAnswers() {
        let policy = HookPolicy(noAnswers: [.vsCode])
        #expect(policy.action(for: .vsCode, asking: true) == .tell)
        #expect(policy.action(for: .vsCode, asking: false) == .tell)
        #expect(policy.action(for: .terminal, asking: true) == .ask)
    }

    @Test("Неизвестный источник идёт как раньше: решить за него нечем")
    func unknown() {
        let policy = HookPolicy(silent: [.terminal], noAnswers: [.vsCode])
        #expect(policy.action(for: nil, asking: true) == .ask)
        #expect(policy.action(for: nil, asking: false) == .tell)
    }

    @Test("Настройки превращаются в то, что читает посредник")
    func fromSettings() {
        var settings = SourceSettings()
        settings[.vsCode].answer = false
        settings[.cursor].read = false
        let policy = settings.hookPolicy
        #expect(policy.action(for: .vsCode, asking: true) == .tell)
        #expect(policy.action(for: .cursor, asking: true) == .leave)
        #expect(policy.action(for: .terminal, asking: true) == .ask)
        #expect(policy.action(for: .cowork, asking: true) == .tell, "на запросы Cowork отвечают в Claude Desktop")
        #expect(policy.action(for: .chat, asking: false) == .leave, "чат выключен по умолчанию")
        settings.set(.claudeCode, on: false)
        #expect(settings.hookPolicy.action(for: .terminal, asking: false) == .leave)
    }

    @Test("Файл запрещает что записано, а его отсутствие или порча не запрещают ничего")
    func file() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("boris-policy-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent(HookPolicy.fileName)
        #expect(HookPolicy.load(from: url) == HookPolicy())
        try HookPolicy(silent: [.cursor], noAnswers: [.vsCode]).save(to: url)
        #expect(HookPolicy.load(from: url) == HookPolicy(silent: [.cursor], noAnswers: [.vsCode]))
        try Data("not json".utf8).write(to: url)
        #expect(HookPolicy.load(from: url) == HookPolicy())
    }
}

@Suite("Снимки экрана по источникам")
struct CaptureRuleTests {
    private func settings(forbidding sources: SourceID...) -> SourceSettings {
        var settings = SourceSettings()
        for source in sources { settings[source].capture = false }
        return settings
    }

    @Test("Без запретов окно видно всегда, что бы в нём ни было")
    func nothingForbidden() {
        #expect(!CaptureRule.hides(shown: Set(SourceID.allCases), unknown: true, settings: SourceSettings()))
    }

    @Test("Запрещённый источник в окне скрывает окно")
    func forbiddenShown() {
        #expect(CaptureRule.hides(shown: [.cowork], settings: settings(forbidding: .cowork)))
    }

    @Test("Разрешённый вместе с запрещённым: скрыто всё окно")
    func mixed() {
        #expect(CaptureRule.hides(shown: [.terminal, .cowork], settings: settings(forbidding: .cowork)))
    }

    @Test("В окне только разрешённые: окно видно")
    func onlyAllowed() {
        #expect(!CaptureRule.hides(shown: [.terminal, .vsCode], settings: settings(forbidding: .cowork)))
        #expect(!CaptureRule.hides(shown: [], settings: settings(forbidding: .cowork)))
    }

    @Test("Работа неизвестно откуда может оказаться запрещённой, поэтому окно скрыто")
    func unknownMayBeForbidden() {
        #expect(CaptureRule.hides(shown: [.terminal], unknown: true, settings: settings(forbidding: .cowork)))
    }

    @Test("Выключенный источник не показан нигде и ничего не скрывает")
    func notReadHidesNothing() {
        var settings = settings(forbidding: .cowork)
        settings[.cowork].read = false
        #expect(settings.captureForbidden.isEmpty)
        #expect(!CaptureRule.hides(shown: [.terminal], unknown: true, settings: settings))
    }
}

@Suite("Пометка о неполных итогах")
struct IncompleteNoteTests {
    @Test("Всё включено: пометки нет, и выключенный по умолчанию чат её не вызывает")
    func allCounted() {
        #expect(SourceWords.incompleteNote(SourceSettings()) == nil)
    }

    @Test("Выключенные называются по именам")
    func namesTheOff() {
        var settings = SourceSettings()
        settings[.cursor].read = false
        settings.set(.cowork, on: false)
        let note = SourceWords.incompleteNote(settings)
        #expect(note?.contains("Cursor") == true)
        #expect(note?.contains("Cowork") == true)
        #expect(note?.contains("VS Code") == false)
    }

    @Test("Весь Claude Code выключен: в пометке все его среды")
    func wholeProduct() {
        var settings = SourceSettings()
        settings.set(.claudeCode, on: false)
        #expect(settings.missingFromTotals == SourceProduct.claudeCode.sources)
    }
}

@Suite("Выключенные источники в нагрузке")
struct LoadOffTests {
    /// A terminal with Claude, VS Code with Claude inside, Cursor with Claude inside, Claude Desktop with its Code tab, Cowork's machine and something else.
    private let world = [
        LoadProcess(pid: 10, parent: 1, cpu: 1),
        LoadProcess(pid: 11, parent: 10, mark: .claude, cpu: 2),
        LoadProcess(pid: 20, parent: 1, mark: .vsCode, cpu: 3),
        LoadProcess(pid: 21, parent: 20, mark: .claude, cpu: 4),
        LoadProcess(pid: 22, parent: 21, cpu: 5),
        LoadProcess(pid: 30, parent: 1, mark: .cursor, cpu: 6),
        LoadProcess(pid: 31, parent: 30, mark: .claude, cpu: 7),
        LoadProcess(pid: 40, parent: 1, mark: .claudeDesktop, cpu: 8),
        LoadProcess(pid: 41, parent: 40, mark: .claude, cpu: 9),
        LoadProcess(pid: 50, parent: 1, mark: .cowork, cpu: 10),
    ]

    private func load(_ settings: SourceSettings, sessions: [String: Int32] = [:], hidden: Set<Int32> = []) -> LoadSplit? {
        LoadGrouping.load(processes: world, sessions: sessions, off: settings.loadOff(hiddenSessions: hidden), totalCPU: 100, usedMemory: 0, physicalMemory: 100).cpu
    }

    private func value(_ split: LoadSplit?, _ group: LoadGroup) -> Double? {
        split?.part(group)?.value
    }

    @Test("Всё включено: каждому своё")
    func allOn() {
        let split = load(SourceSettings())
        #expect(value(split, .claude) == Double(2 + 4 + 5 + 7 + 9))
        #expect(value(split, .vsCode) == 3)
        #expect(value(split, .cursor) == 6)
        #expect(value(split, .claudeDesktop) == 8)
        #expect(value(split, .cowork) == 10)
    }

    @Test("Выключен терминал: Claude в терминале уходит в «Остальное», а Claude в редакторах остаётся Claude")
    func terminalOff() {
        var settings = SourceSettings()
        settings[.terminal].read = false
        let split = load(settings)
        #expect(value(split, .claude) == Double(4 + 5 + 7 + 9))
        #expect(value(split, .vsCode) == 3)
        #expect(value(split, .cursor) == 6)
    }

    @Test("Выключен Cursor: строки нет, и его Claude тоже в «Остальном», а VS Code не тронут")
    func cursorOff() {
        var settings = SourceSettings()
        settings[.cursor].read = false
        let split = load(settings)
        #expect(value(split, .cursor) == nil)
        #expect(value(split, .claude) == Double(2 + 4 + 5 + 9))
        #expect(value(split, .vsCode) == 3)
    }

    @Test("Выключена только вкладка Code: её Claude в «Остальном», а Claude Desktop остаётся, потому что есть Cowork")
    func codeTabOff() {
        var settings = SourceSettings()
        settings[.claudeDesktop].read = false
        let split = load(settings)
        #expect(value(split, .claude) == Double(2 + 4 + 5 + 7))
        #expect(value(split, .claudeDesktop) == 8)
        #expect(value(split, .cowork) == 10)
    }

    @Test("Выключен Cowork: его машины нет, а Claude Desktop остаётся, пока за вкладкой Code следят")
    func coworkOff() {
        var settings = SourceSettings()
        settings.set(.cowork, on: false)
        let split = load(settings)
        #expect(value(split, .cowork) == nil)
        #expect(value(split, .claudeDesktop) == 8)
    }

    @Test("Строки Claude Desktop нет, только когда не следят ни за чем в нём")
    func desktopOff() {
        var settings = SourceSettings()
        settings[.claudeDesktop].read = false
        settings.set(.cowork, on: false)
        #expect(value(load(settings), .claudeDesktop) == nil, "чат и так выключен")
        settings.set(.chat, on: true)
        #expect(value(load(settings), .claudeDesktop) == 8, "чат включён, и приложение на виду")
    }

    @Test("Выключен весь Claude Code: строки Claude нет, и редакторы тоже")
    func wholeClaudeCode() {
        var settings = SourceSettings()
        settings.set(.claudeCode, on: false)
        let split = load(settings)
        #expect(value(split, .claude) == nil)
        #expect(value(split, .vsCode) == nil)
        #expect(value(split, .cursor) == nil)
        #expect(value(split, .cowork) == 10)
    }

    @Test("Программа на SDK со своим файлом сессии уходит сама, а Claude в терминале остаётся")
    func hiddenSession() {
        var settings = SourceSettings()
        settings[.program].read = false
        let split = load(settings, hidden: [11])
        #expect(value(split, .claude) == Double(4 + 5 + 7 + 9))
    }

    @Test("Сессия, показанная в Boris, считается за Claude, даже если редактор вокруг неё выключен")
    func shownSessionInsideOffEditor() {
        var settings = SourceSettings()
        settings[.vsCode].read = false
        let split = load(settings, sessions: ["s": 21])
        #expect(value(split, .claude) == Double(2 + 4 + 5 + 7 + 9))
        #expect(value(split, .vsCode) == nil)
    }

    @Test("Части дают в сумме общую нагрузку при любом выборе", arguments: SourceID.allCases)
    func sumStays(source: SourceID) {
        var settings = SourceSettings()
        settings[source].read = false
        let split = load(settings)
        #expect(split?.parts.reduce(0) { $0 + $1.points } == split?.points)
    }

    @Test("Заметка под блоком называет то, что ушло в «Остальное»")
    func note() {
        var settings = SourceSettings()
        settings[.terminal].read = false
        settings[.cursor].read = false
        let found = LoadGrouping.load(processes: world, sessions: [:], off: settings.loadOff(), totalCPU: 100, usedMemory: 0, physicalMemory: 100)
        #expect(found.offWithProcesses == [.claude, .cursor])
    }

    @Test("Выключено то, чего нет на Mac: заметка молчит")
    func noteOnlyWhatRuns() {
        var settings = SourceSettings()
        settings[.cursor].read = false
        let tree = world.filter { $0.mark != .cursor && $0.pid != 31 }
        let found = LoadGrouping.load(processes: tree, sessions: [:], off: settings.loadOff(), totalCPU: 100, usedMemory: 0, physicalMemory: 100)
        #expect(found.offWithProcesses.isEmpty)
    }
}
