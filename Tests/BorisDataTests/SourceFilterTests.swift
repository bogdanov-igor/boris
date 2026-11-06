import BorisCore
import Darwin
import Foundation
import Testing
@testable import BorisData

/// A made-up Claude in a throwaway folder: one session in each source, each with its own agent and workflow.
private final class Fixture: @unchecked Sendable {
    let home = TempFolder()
    let main: ClaudePaths
    let cowork: ClaudePaths

    /// Session id of each source, as in the logs.
    static let sessions: [(id: String, entrypoint: String)] = [
        ("term", "cli"),
        ("code", "claude-vscode"),
        ("desk", "claude-desktop"),
        ("prog", "sdk-ts"),
    ]

    init() {
        main = ClaudePaths(root: home.url.appendingPathComponent(".claude"))
        var cowork = ClaudePaths(root: home.url.appendingPathComponent("cowork/.claude"))
        cowork.processesAreHere = false
        self.cowork = cowork
        home.write(".claude/sessions/.keep", "")
        for (id, entrypoint) in Self.sessions {
            addSession(id, entrypoint: entrypoint, to: ".claude")
        }
        addSession("work", entrypoint: "local-agent", to: "cowork/.claude")
    }

    /// Every message has its own id and spends `tokens`, so a sum tells exactly who was counted.
    func addSession(_ id: String, entrypoint: String, to root: String, tokens: Int = 100) {
        let project = "\(root)/projects/-x-\(id)"
        home.write("\(project)/\(id).jsonl", Self.answer(id: "\(id)-m", entrypoint: entrypoint, tokens: tokens) + Self.answer(id: "\(id)-n", entrypoint: entrypoint, tokens: tokens))
        // An agent's own file may not say where it runs, and its session's does.
        home.write("\(project)/\(id)/subagents/agent-\(id)a.jsonl", #"{"type":"assistant","timestamp":"2026-11-05T12:00:00.000Z","message":{"id":"\#(id)-a","model":"opus","stop_reason":"end_turn","content":[],"usage":{"input_tokens":\#(tokens),"output_tokens":0}}}"# + "\n")
        home.write("\(project)/\(id)/subagents/agent-\(id)a.meta.json", #"{"description":"Агент"}"#)
        home.write("\(project)/\(id)/subagents/workflows/wf_\(id)/journal.jsonl", #"{"type":"launched"}"# + "\n")
        home.write("\(project)/\(id)/workflows/wf_\(id).json", "{}")
    }

    static func answer(id: String, entrypoint: String, tokens: Int) -> String {
        #"{"type":"assistant","timestamp":"2026-11-05T12:00:00.000Z","cwd":"/x/demo","entrypoint":"\#(entrypoint)","message":{"id":"\#(id)","model":"opus","stop_reason":"end_turn","content":[],"usage":{"input_tokens":\#(tokens),"output_tokens":0}}}"# + "\n"
    }

    var roots: [ClaudePaths] { [main, cowork] }

    func filter(_ off: Set<SourceID>) -> SourceFilter {
        SourceFilter(off: off)
    }

    var allFiles: [URL] {
        guard let walker = FileManager.default.enumerator(at: home.url, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
        return walker.compactMap { $0 as? URL }.filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true }
    }

    /// The files whose contents were read while `work` ran, known from their access times, so no reader can get around it.
    func filesRead(during work: () async -> Void) async -> Set<String> {
        let long = timespec(tv_sec: 1_000_000_000, tv_nsec: 0)
        for file in allFiles {
            var info = stat()
            stat(file.path, &info)
            var times = [long, info.st_mtimespec]
            utimensat(AT_FDCWD, file.path, &times, 0)
        }
        await work()
        return Set(allFiles.filter { file in
            var info = stat()
            stat(file.path, &info)
            return info.st_atimespec.tv_sec != long.tv_sec
        }.map { file in
            // The temporary folder has two spellings, with `/private` and without.
            file.path.components(separatedBy: home.url.lastPathComponent + "/").last ?? file.path
        })
    }

    /// Everything Boris reads Claude's files with.
    func readWithEverything(_ filter: SourceFilter) async {
        let others: @Sendable () -> [ClaudePaths] = { [cowork] in [cowork] }
        let scanner = RunScanner(paths: main, others: others, filter: filter)
        await scanner.markDiscovery()
        _ = await scanner.scan(now: Date())
        _ = await TokenIndex(cacheFile: nil).update(roots: roots, filter: filter)
        _ = await SessionHistory(paths: main, others: others, filter: filter).sessions()
        let losses = LossIndex(cacheFile: nil)
        await losses.update(roots: roots, filter: filter)
        _ = await losses.book(period: .all, tokens: [], live: [], now: Date())
    }

    func tokens(_ filter: SourceFilter, index: TokenIndex = TokenIndex(cacheFile: nil)) async -> [String: Int] {
        await index.update(roots: roots, filter: filter)
        var sums: [String: Int] = [:]
        for record in await index.records() { sums[record.sessionId, default: 0] += record.usage.total }
        return sums
    }
}

@Suite("Выключенный источник не читается", .serialized)
struct SourceFilterReadingTests {
    private func atimeWorks() throws -> Bool {
        let folder = TempFolder()
        let file = folder.write("probe.txt", "x")
        var times = [timespec(tv_sec: 1_000_000_000, tv_nsec: 0), timespec(tv_sec: 1_700_000_000, tv_nsec: 0)]
        utimensat(AT_FDCWD, file.path, &times, 0)
        _ = try Data(contentsOf: file)
        var info = stat()
        stat(file.path, &info)
        return info.st_atimespec.tv_sec != 1_000_000_000
    }

    @Test("Проверка не слепая: без выключенных источников файлы читаются, и она это видит")
    func theCheckSeesReads() async throws {
        guard try atimeWorks() else { return }
        let fixture = Fixture()
        let read = await fixture.filesRead { await fixture.readWithEverything(fixture.filter([])) }
        #expect(read.contains(".claude/projects/-x-code/code.jsonl"))
        #expect(read.contains(".claude/projects/-x-code/code/subagents/agent-codea.jsonl"))
        #expect(read.contains(".claude/projects/-x-code/code/subagents/workflows/wf_code/journal.jsonl"))
        #expect(read.contains("cowork/.claude/projects/-x-work/work.jsonl"))
    }

    @Test("Файлы Cowork не открываются вообще, ни один")
    func coworkUntouched() async throws {
        guard try atimeWorks() else { return }
        let fixture = Fixture()
        let read = await fixture.filesRead { await fixture.readWithEverything(fixture.filter([.cowork])) }
        #expect(read.filter { $0.hasPrefix("cowork/") }.isEmpty, "\(read.filter { $0.hasPrefix("cowork/") })")
        #expect(read.contains(".claude/projects/-x-term/term.jsonl"), "остальные читаются как обычно")
    }

    @Test("Всё, что вокруг сессии выключенной среды, не открывается: агенты, журналы, итоги запусков")
    func agentsUntouched() async throws {
        guard try atimeWorks() else { return }
        let fixture = Fixture()
        let read = await fixture.filesRead { await fixture.readWithEverything(fixture.filter([.vsCode])) }
        let around = read.filter { $0.hasPrefix(".claude/projects/-x-code/code/") }
        #expect(around.isEmpty, "\(around)")
        #expect(read.contains(".claude/projects/-x-term/term/subagents/agent-terma.jsonl"), "у других сред всё на месте")
    }

    @Test("Весь Claude Code выключен: его папка не открывается совсем, Cowork читается")
    func wholeProductUntouched() async throws {
        guard try atimeWorks() else { return }
        let fixture = Fixture()
        let read = await fixture.filesRead { await fixture.readWithEverything(fixture.filter(Set(SourceProduct.claudeCode.sources))) }
        #expect(read.filter { $0.hasPrefix(".claude/") }.isEmpty, "\(read.filter { $0.hasPrefix(".claude/") })")
        #expect(read.contains("cowork/.claude/projects/-x-work/work.jsonl"))
    }

    @Test("Всё выключено: не открыт ни один файл")
    func everythingUntouched() async throws {
        guard try atimeWorks() else { return }
        let fixture = Fixture()
        let read = await fixture.filesRead { await fixture.readWithEverything(fixture.filter(Set(SourceID.allCases))) }
        #expect(read.isEmpty, "\(read)")
    }

    @Test("По умолчанию выключен только чат, и ради него журналы не открываются")
    func defaultsReadNoHeads() async throws {
        guard try atimeWorks() else { return }
        let fixture = Fixture()
        let filter = SourceFilter(off: SourceSettings().readingOff)
        #expect(filter.off == [.chat])
        let read = await fixture.filesRead {
            for (id, _) in Fixture.sessions { #expect(filter.allows(transcript: fixture.main.projects.appendingPathComponent("-x-\(id)/\(id).jsonl"))) }
        }
        #expect(read.isEmpty, "\(read)")
    }

    @Test("Лимиты не читаются, когда Claude Code выключен целиком")
    func limitsStayClosed() async throws {
        let fixture = Fixture()
        fixture.home.write(".claude/.claude.json", #"{"cachedUsageUtilization":{"fetchedAtMs":1000,"utilization":{"five_hour":{"utilization":42}}}}"#)
        let on = await RunScanner(paths: fixture.main).scan(now: Date())
        #expect(on.usage != nil, "проверка видит лимиты, когда им можно")
        let off = await RunScanner(paths: fixture.main, filter: fixture.filter(Set(SourceProduct.claudeCode.sources))).scan(now: Date())
        #expect(off.usage == nil)
    }
}

@Suite("Итоги без выключенных источников")
struct SourceFilterTotalsTests {
    @Test("Сумма считается без выключенной среды, вместе с её агентами")
    func withoutTheSource() async {
        let fixture = Fixture()
        let all = await fixture.tokens(fixture.filter([]))
        #expect(all == ["term": 300, "code": 300, "desk": 300, "prog": 300, "work": 300])
        let off = await fixture.tokens(fixture.filter([.vsCode]))
        #expect(off == ["term": 300, "desk": 300, "prog": 300, "work": 300])
    }

    @Test("Каждая среда выключается сама по себе", arguments: [
        (SourceID.terminal, "term"), (.vsCode, "code"), (.claudeDesktop, "desk"), (.program, "prog"), (.cowork, "work"),
    ])
    func each(source: SourceID, session: String) async {
        let fixture = Fixture()
        let sums = await fixture.tokens(fixture.filter([source]))
        #expect(sums[session] == nil)
        #expect(sums.count == 4)
    }

    @Test("Включение снова восстанавливает всё из логов, и кэш не держит старого")
    func restored() async throws {
        let fixture = Fixture()
        let cache = fixture.home.url.appendingPathComponent("support/token-index.json")
        let index = TokenIndex(cacheFile: cache)
        let all = await fixture.tokens(fixture.filter([]), index: index)
        let off = await fixture.tokens(fixture.filter([.vsCode]), index: index)
        #expect(off["code"] == nil)
        let saved = try String(contentsOf: cache, encoding: .utf8)
        #expect(!saved.contains("code.jsonl"), "выключенное не остаётся и в файле Boris")
        let back = await fixture.tokens(fixture.filter([]), index: index)
        #expect(back == all)
    }

    @Test("То же после перезапуска: новый индекс с кэшем считает так же")
    func restoredAfterRestart() async {
        let fixture = Fixture()
        let cache = fixture.home.url.appendingPathComponent("support/token-index.json")
        let all = await fixture.tokens(fixture.filter([]), index: TokenIndex(cacheFile: cache))
        _ = await fixture.tokens(fixture.filter([.cowork]), index: TokenIndex(cacheFile: cache))
        let back = await fixture.tokens(fixture.filter([]), index: TokenIndex(cacheFile: cache))
        #expect(back == all)
    }

    @Test("Новая запись выключенной среды не считается, пока она выключена, и считается потом")
    func writtenWhileOff() async {
        let fixture = Fixture()
        let index = TokenIndex(cacheFile: nil)
        _ = await fixture.tokens(fixture.filter([.vsCode]), index: index)
        fixture.home.append(".claude/projects/-x-code/code.jsonl", Fixture.answer(id: "code-new", entrypoint: "claude-vscode", tokens: 50))
        let off = await fixture.tokens(fixture.filter([.vsCode]), index: index)
        #expect(off["code"] == nil)
        let on = await fixture.tokens(fixture.filter([]), index: index)
        #expect(on["code"] == 350)
    }

    @Test("Потери считаются без выключенной среды и возвращаются")
    func losses() async {
        let fixture = Fixture()
        fixture.home.append(".claude/projects/-x-code/code.jsonl", #"{"type":"assistant","isApiErrorMessage":true,"timestamp":"2026-11-05T13:00:00.000Z","cwd":"/x/demo","entrypoint":"claude-vscode","uuid":"e1","message":{"id":"err","content":[{"type":"text","text":"API Error: 500"}]}}"# + "\n")
        fixture.home.append(".claude/projects/-x-term/term.jsonl", #"{"type":"assistant","isApiErrorMessage":true,"timestamp":"2026-11-05T13:00:00.000Z","cwd":"/x/demo","entrypoint":"cli","uuid":"e2","message":{"id":"err2","content":[{"type":"text","text":"API Error: 500"}]}}"# + "\n")
        let index = LossIndex(cacheFile: nil)
        await index.update(roots: fixture.roots, filter: fixture.filter([]))
        let all = await index.history(live: []).entries.map(\.sessionId)
        #expect(all.contains("code"))
        #expect(all.contains("term"))
        await index.update(roots: fixture.roots, filter: fixture.filter([.vsCode]))
        let off = await index.history(live: []).entries.map(\.sessionId)
        #expect(!off.contains("code"))
        #expect(off.contains("term"))
        await index.update(roots: fixture.roots, filter: fixture.filter([]))
        #expect(await index.history(live: []).entries.map(\.sessionId).contains("code"))
    }
}

@Suite("Сессии без выключенных источников")
struct SourceFilterSessionsTests {
    /// A session whose process is really running: the test itself.
    private func live(_ fixture: Fixture, id: String, entrypoint: String) {
        let pid = ProcessInfo.processInfo.processIdentifier
        fixture.home.write(".claude/sessions/\(pid).json", #"{"sessionId":"\#(id)","pid":\#(pid),"status":"busy","entrypoint":"\#(entrypoint)"}"#)
    }

    private func scanner(_ fixture: Fixture, off: Set<SourceID>) -> RunScanner {
        let cowork = fixture.cowork
        return RunScanner(paths: fixture.main, others: { [cowork] }, filter: fixture.filter(off))
    }

    @Test("Сессия выключенной среды исчезает из работы, а Boris помнит только её процесс")
    func hidden() async throws {
        let fixture = Fixture()
        live(fixture, id: "term", entrypoint: "cli")
        let on = await scanner(fixture, off: []).scan(now: Date())
        #expect(on.sessions.map(\.sessionId) == ["term"])
        #expect(on.hiddenSessions.isEmpty)
        let off = await scanner(fixture, off: [.terminal]).scan(now: Date())
        #expect(off.sessions.isEmpty)
        #expect(off.hiddenSessions == ["term": ProcessInfo.processInfo.processIdentifier])
    }

    @Test("Запуски и агенты выключенной среды не показываются вместе с ней")
    func runsAndAgentsGo() async throws {
        let fixture = Fixture()
        let scanner = scanner(fixture, off: [.vsCode])
        await scanner.markDiscovery()
        let world = await scanner.scan(now: Date())
        #expect(!world.runs.contains { $0.sessionId == "code" })
        #expect(!world.agents.contains { $0.sessionId == "code" })
        #expect(world.runs.contains { $0.sessionId == "term" })
        #expect(world.agents.contains { $0.sessionId == "term" })
    }

    @Test("Журнал сессии выключенной среды не отдаётся и странице сессии")
    func transcriptClosed() async {
        let fixture = Fixture()
        let scanner = scanner(fixture, off: [.vsCode])
        #expect(await scanner.sessionTranscript("code") == nil)
        #expect(await scanner.sessionTranscript("term") != nil)
        // Asked a second time, from what it remembers.
        #expect(await scanner.sessionTranscript("code") == nil)
    }

    @Test("Сессия без своего файла тоже решается по журналу")
    func unlisted() async throws {
        let fixture = Fixture()
        let filter = fixture.filter([.cowork])
        let cowork = fixture.cowork
        let scanner = RunScanner(paths: fixture.main, others: { [cowork] }, filter: filter)
        _ = await scanner.scan(now: Date())
        fixture.home.write(".claude/projects/-x-new/new.jsonl", Fixture.answer(id: "new", entrypoint: "local-agent", tokens: 1))
        fixture.home.write(".claude/projects/-x-other/other.jsonl", Fixture.answer(id: "other", entrypoint: "sdk-ts", tokens: 1))
        await scanner.markDiscovery()
        let world = await scanner.scan(now: Date())
        #expect(!world.sessions.contains { $0.sessionId == "new" })
        #expect(world.sessions.contains { $0.sessionId == "other" })
    }

    @Test("Прошлые сессии выключенной среды уходят со страницы и возвращаются")
    func pastSessions() async {
        let fixture = Fixture()
        let cowork = fixture.cowork
        func ids(_ off: Set<SourceID>) async -> Set<String> {
            Set(await SessionHistory(paths: fixture.main, others: { [cowork] }, filter: fixture.filter(off)).sessions().map(\.id))
        }
        #expect(await ids([]) == ["term", "code", "desk", "prog", "work"])
        #expect(await ids([.vsCode, .cowork]) == ["term", "desk", "prog"])
        #expect(await ids([]) == ["term", "code", "desk", "prog", "work"])
    }

    @Test("Без выключенных источников журналы не открываются ради фильтра")
    func nothingOffCostsNothing() {
        let filter = SourceFilter()
        // A file that does not exist would say nothing, so a true answer here cannot have come from reading it.
        #expect(filter.allows(transcript: URL(fileURLWithPath: "/nonexistent/x.jsonl")))
        #expect(filter.reads(root: ClaudePaths(root: URL(fileURLWithPath: "/nonexistent"))))
    }

    @Test("Запись, которая пока ничего не говорит, спрашивается снова, когда файл вырос")
    func saysLater() {
        let fixture = Fixture()
        let filter = fixture.filter([.terminal])
        let file = fixture.home.write(".claude/projects/-x-new/new.jsonl", #"{"type":"summary"}"# + "\n")
        #expect(filter.allows(transcript: file))
        fixture.home.append(".claude/projects/-x-new/new.jsonl", Fixture.answer(id: "n", entrypoint: "cli", tokens: 1))
        #expect(!filter.allows(transcript: file))
    }
}

@Suite("Cursor и VS Code", .serialized)
struct EditorTests {
    /// A real process whose executable lies inside a made-up app. It has to be one of ours: the system kills a copy of its own programs.
    private final class FakeEditor {
        private let process = Process()
        var pid: Int32 { process.processIdentifier }

        init(app: String, in folder: TempFolder) throws {
            let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            let built = root.appendingPathComponent(".build/debug/boris-dump")
            let binary = folder.url.appendingPathComponent("\(app)/Contents/MacOS/boris-dump")
            try FileManager.default.createDirectory(at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: built, to: binary)
            process.executableURL = binary
            // Stays alive for a good minute, and reads nothing of the person's.
            process.arguments = ["load", "25"]
            process.environment = ["BORIS_ONLY_THIS_FOLDER": "1", "CLAUDE_CONFIG_DIR": folder.url.appendingPathComponent("nowhere").path, "HOME": NSHomeDirectory()]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
        }

        func stop() {
            process.terminate()
            process.waitUntilExit()
        }
    }

    @Test("Настоящий процесс внутри Cursor.app определяется как Cursor, хотя пишет claude-vscode")
    func cursorProcess() async throws {
        let folder = TempFolder()
        let cursor = try FakeEditor(app: "Cursor.app", in: folder)
        defer { cursor.stop() }
        #expect(SourceDetection.editor(of: cursor.pid) == .cursor)

        let book = EditorBook()
        let session = SessionInfo(sessionId: "s", pid: cursor.pid, entrypoint: "claude-vscode")
        let seen = book.identified(session)
        #expect(seen.environment == .cursor)
        #expect(seen.isEditorSession)
    }

    @Test("Настоящий процесс внутри VS Code остаётся VS Code")
    func vsCodeProcess() throws {
        let folder = TempFolder()
        let code = try FakeEditor(app: "Visual Studio Code.app", in: folder)
        defer { code.stop() }
        let seen = EditorBook().identified(SessionInfo(sessionId: "s", pid: code.pid, entrypoint: "claude-vscode"))
        #expect(seen.environment == .vsCode)
    }

    @Test("Выключен Cursor: его сессия скрыта вместе с журналом, а сессия VS Code видна, при одном и том же слове в логах")
    func filteringTwoEditors() async throws {
        let folder = TempFolder()
        let cursor = try FakeEditor(app: "Cursor.app", in: folder)
        defer { cursor.stop() }
        let code = try FakeEditor(app: "Visual Studio Code.app", in: folder)
        defer { code.stop() }
        let home = TempFolder()
        home.write("sessions/\(cursor.pid).json", #"{"sessionId":"in-cursor","pid":\#(cursor.pid),"status":"busy","entrypoint":"claude-vscode"}"#)
        home.write("sessions/\(code.pid).json", #"{"sessionId":"in-code","pid":\#(code.pid),"status":"busy","entrypoint":"claude-vscode"}"#)
        for id in ["in-cursor", "in-code"] {
            home.write("projects/p/\(id).jsonl", Fixture.answer(id: id, entrypoint: "claude-vscode", tokens: 10))
        }
        let paths = ClaudePaths(root: home.url)
        let filter = SourceFilter(off: [.cursor])
        let scanner = RunScanner(paths: paths, filter: filter)
        let world = await scanner.scan(now: Date())
        #expect(world.sessions.map(\.sessionId) == ["in-code"])
        #expect(world.hiddenSessions == ["in-cursor": cursor.pid])
        #expect(world.sessions.first?.environment == .vsCode)

        // What was seen while they run also says where the logs belong.
        let index = TokenIndex(cacheFile: nil)
        await index.update(roots: [paths], filter: filter)
        #expect(Set(await index.records().map(\.sessionId)) == ["in-code"])

        let both = SourceFilter(off: [.vsCode], editors: filter.editors)
        await index.update(roots: [paths], filter: both)
        let records = await index.records()
        #expect(Set(records.map(\.sessionId)) == ["in-cursor"])
        #expect(records.first?.entrypoint == SourceDetection.cursorEntrypoint, "расход этой сессии показан как Cursor")
    }

    @Test("Сессия Cursor остаётся Cursor и после её конца, и после перезапуска Boris")
    func remembered() throws {
        let folder = TempFolder()
        let file = folder.url.appendingPathComponent("support/\(EditorBook.fileName)")
        let cursor = try FakeEditor(app: "Cursor.app", in: folder)
        let book = EditorBook(file: file)
        _ = book.identified(SessionInfo(sessionId: "s", pid: cursor.pid, entrypoint: "claude-vscode"))
        cursor.stop()
        #expect(book.entrypoint("claude-vscode", session: "s") == SourceDetection.cursorEntrypoint)
        let reopened = EditorBook(file: file)
        #expect(reopened.entrypoint("claude-vscode", session: "s") == SourceDetection.cursorEntrypoint)
        #expect(reopened.entrypoint("claude-vscode", session: "other") == "claude-vscode", "о других сессиях ничего не известно")
        let saved = try String(contentsOf: file, encoding: .utf8)
        #expect(saved == #"["s"]"#, "в файле только номер сессии")
    }

    @Test("Завершившаяся сессия, которую никто не видел, считается VS Code")
    func unseenIsVSCode() {
        let seen = EditorBook().identified(SessionInfo(sessionId: "s", pid: 999_999, entrypoint: "claude-vscode"))
        #expect(seen.environment == .vsCode)
    }

    @Test("Если на Mac есть только Cursor, сессия без свидетелей может быть только его")
    func onlyCursor() throws {
        let folder = TempFolder()
        let code = try FakeEditor(app: "Visual Studio Code.app", in: folder)
        defer { code.stop() }
        let book = EditorBook(onlyCursorInstalled: true)
        #expect(book.entrypoint("claude-vscode", session: "old") == SourceDetection.cursorEntrypoint)
        #expect(book.identified(SessionInfo(sessionId: "live", pid: code.pid, entrypoint: "claude-vscode")).environment == .vsCode, "процессы важнее догадки")
        #expect(book.entrypoint("cli", session: "old") == "cli")
    }

    @Test("Какие редакторы установлены, видно по папкам с программами")
    func installed() {
        let cursorOnly = TempFolder()
        cursorOnly.write("Cursor.app/x", "")
        cursorOnly.write("Safari.app/x", "")
        #expect(EditorBook.isOnlyCursorInstalled(appFolders: [cursorOnly.url]))
        let both = TempFolder()
        both.write("Cursor.app/x", "")
        both.write("Visual Studio Code - Insiders.app/x", "")
        #expect(!EditorBook.isOnlyCursorInstalled(appFolders: [both.url]))
        let neither = TempFolder()
        #expect(!EditorBook.isOnlyCursorInstalled(appFolders: [neither.url]))
    }

    @Test("Терминал не спрашивает о редакторе, в каком бы окне его ни открыли")
    func terminalStays() throws {
        let folder = TempFolder()
        let cursor = try FakeEditor(app: "Cursor.app", in: folder)
        defer { cursor.stop() }
        let seen = EditorBook().identified(SessionInfo(sessionId: "s", pid: cursor.pid, entrypoint: "cli"))
        #expect(seen.environment == .terminal)
    }
}

@Suite("Папки и источники")
struct SourceRootsTests {
    @Test("Папка Cowork закрывается своим переключателем, общая папка только вместе со всеми средами")
    func roots() {
        let main = ClaudePaths(root: URL(fileURLWithPath: "/x/.claude"))
        var cowork = ClaudePaths(root: URL(fileURLWithPath: "/x/cowork/.claude"))
        cowork.processesAreHere = false
        #expect(SourceFilter(off: [.terminal]).reads(root: main))
        #expect(SourceFilter(off: [.terminal]).reads(root: cowork))
        #expect(SourceFilter(off: [.cowork]).reads(root: main))
        #expect(!SourceFilter(off: [.cowork]).reads(root: cowork))
        #expect(!SourceFilter(off: [.terminal, .vsCode, .cursor, .claudeDesktop, .program]).reads(root: main))
        #expect(SourceFilter(off: [.terminal, .vsCode, .cursor, .claudeDesktop]).reads(root: main), "программы на SDK пишут туда же")
        #expect(!SourceFilter(off: Set(SourceProduct.claudeCode.sources)).reads(root: main))
    }
}
