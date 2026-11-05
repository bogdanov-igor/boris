import BorisCore
import Darwin
import Foundation
import Testing
@testable import BorisData

/// The real Claude Code is never started here: every test gives the probe a small script of its own.
@Suite("Скрытое обновление лимитов", .serialized)
struct UsageProbeTests {
    private final class Place {
        let folder = TempFolder()
        let profile: URL
        let script: URL
        let logs: URL

        /// - Parameter body: the shell script that stands in for Claude Code.
        init(fetchedAgo: TimeInterval = 3600, body: String) throws {
            profile = folder.write("claude.json", Self.profile(fetchedAt: Date().addingTimeInterval(-fetchedAgo), percent: 34))
            logs = folder.url.appendingPathComponent("logs")
            try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
            script = folder.write("fake-claude", "#!/bin/sh\n\(body)\n")
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        }

        static func profile(fetchedAt: Date, percent: Int) -> String {
            #"{"cachedUsageUtilization":{"fetchedAtMs":\#(Int(fetchedAt.timeIntervalSince1970 * 1000)),"utilization":{"seven_day":{"utilization":\#(percent)}}}}"#
        }

        var probe: UsageProbe {
            var probe = UsageProbe(binary: script, folder: folder.url.appendingPathComponent("usage-probe"), profile: profile, configFolder: nil)
            probe.trustAfter = 0.1
            probe.askAfter = 0.3
            probe.timeout = 8
            probe.exitGrace = 2
            return probe
        }

        func log(_ name: String) -> String? {
            try? String(contentsOf: logs.appendingPathComponent(name), encoding: .utf8)
        }

        /// A line of shell that rewrites the cache the way `/usage` does.
        var writesFresh: String {
            let fresh = Self.profile(fetchedAt: Date(), percent: 47)
            return "cat > '\(profile.path)' <<'JSON'\n\(fresh)\nJSON"
        }
    }

    private func run(_ probe: UsageProbe) async -> UsageProbe.Outcome {
        await Task.detached { probe.run() }.value
    }

    @Test("/usage обновляет кэш: новое значение и новый возраст")
    func refreshed() async throws {
        let place = try Place(body: "")
        try """
        #!/bin/sh
        pwd > '\(place.logs.path)/cwd'
        echo "$@" > '\(place.logs.path)/arguments'
        echo Welcome
        read line
        echo "$line" > '\(place.logs.path)/typed'
        \(place.writesFresh)
        sleep 30
        """.write(to: place.script, atomically: true, encoding: .utf8)

        let old = try #require(UsageReader.read(place.profile))
        #expect(await run(place.probe) == .refreshed)

        let new = try #require(UsageReader.read(place.profile))
        #expect(new.windows.first?.percent == 47)
        let oldDate = try #require(old.fetchedAt)
        let newDate = try #require(new.fetchedAt)
        #expect(newDate > oldDate)
        #expect(place.log("typed")?.contains("/usage") == true)
        #expect(place.log("arguments")?.contains("--setting-sources local") == true)
        let cwd = try #require(place.log("cwd")).trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(cwd.hasSuffix("/usage-probe"))
    }

    @Test("Окружение чистое: приложение не передаёт своего и не передаёт настроек")
    func cleanEnvironment() async throws {
        let place = try Place(body: "")
        setenv("BORIS_TEST_PRIVATE", "1", 1)
        defer { unsetenv("BORIS_TEST_PRIVATE") }
        try """
        #!/bin/sh
        env > '\(place.logs.path)/env'
        echo Welcome
        read line
        \(place.writesFresh)
        """.write(to: place.script, atomically: true, encoding: .utf8)
        #expect(await run(place.probe) == .refreshed)
        let env = try #require(place.log("env"))
        #expect(!env.contains("BORIS_TEST_PRIVATE"))
        #expect(env.contains("TERM=xterm-256color"))
        #expect(!env.contains("CLAUDE_CONFIG_DIR"))
    }

    @Test("Другая папка настроек передаётся, чтобы кэш обновился там же")
    func configFolder() async throws {
        let place = try Place(body: "")
        try """
        #!/bin/sh
        env > '\(place.logs.path)/env'
        echo Welcome
        read line
        \(place.writesFresh)
        """.write(to: place.script, atomically: true, encoding: .utf8)
        var probe = place.probe
        probe.configFolder = "/x/claude-config"
        #expect(await run(probe) == .refreshed)
        #expect(place.log("env")?.contains("CLAUDE_CONFIG_DIR=/x/claude-config") == true)
    }

    @Test("На вопрос о доверии отвечает «да» только в своей пустой папке")
    func trustQuestion() async throws {
        let place = try Place(body: "")
        try """
        #!/bin/sh
        printf 'Do you trust the files in this folder?\\n'
        read answer
        printf '%s' "$answer" | od -c > '\(place.logs.path)/answer'
        echo Welcome
        read line
        echo "$line" > '\(place.logs.path)/typed'
        \(place.writesFresh)
        """.write(to: place.script, atomically: true, encoding: .utf8)
        #expect(await run(place.probe) == .refreshed)
        // The arrow down to «Yes» and then Enter.
        #expect(place.log("answer")?.contains("033") == true)
        #expect(place.log("typed")?.contains("/usage") == true)
    }

    @Test("Вопрос о доверии появился позже обычного: /usage и Enter не уходят в него и не выбирают «нет»")
    func slowTrustQuestion() async throws {
        let place = try Place(body: "")
        // Terminal settings and a window title come first and are not a screen yet.
        try """
        #!/bin/sh
        printf '\\033[?2004h\\033]0;claude code\\007'
        sleep 1.2
        printf 'Do you trust the files in this folder?\\n'
        read answer
        printf '%s' "$answer" | od -c > '\(place.logs.path)/answer'
        echo Welcome
        read line
        echo "$line" > '\(place.logs.path)/typed'
        \(place.writesFresh)
        """.write(to: place.script, atomically: true, encoding: .utf8)
        #expect(await run(place.probe) == .refreshed)
        #expect(place.log("answer")?.contains("033") == true)
        #expect(place.log("answer")?.contains("u   s   a") == false)
        #expect(place.log("typed")?.contains("/usage") == true)
    }

    @Test("Программа ещё ничего не показала: команда не набирается вслепую")
    func nothingOnScreen() async throws {
        let place = try Place(body: "")
        try """
        #!/bin/sh
        read line
        touch '\(place.logs.path)/typed'
        sleep 30
        """.write(to: place.script, atomically: true, encoding: .utf8)
        var probe = place.probe
        probe.timeout = 1.5
        #expect(await run(probe) == .failed)
        #expect(place.log("typed") == nil)
    }

    @Test("Сбой: Claude Code закрылся сразу. Старое значение на месте с настоящим возрастом", arguments: ["exit 1", "exit 0"])
    func quitsAtOnce(body: String) async throws {
        let place = try Place(body: body)
        let before = try Data(contentsOf: place.profile)
        #expect(await run(place.probe) == .failed)
        #expect(try Data(contentsOf: place.profile) == before)
    }

    @Test("Нет интернета: команда не обновляет кэш, и по истечении времени всё кончается сбоем")
    func noInternet() async throws {
        let place = try Place(body: "echo Welcome\nread line\nsleep 30")
        let before = try #require(UsageReader.read(place.profile))
        var probe = place.probe
        probe.timeout = 1.5
        let began = Date()
        #expect(await run(probe) == .failed)
        #expect(Date().timeIntervalSince(began) < 8)
        #expect(UsageReader.read(place.profile) == before)
    }

    @Test("Запись в файл без нового времени не считается обновлением")
    func rewriteWithoutFreshData() async throws {
        let place = try Place(body: "")
        let same = try String(contentsOf: place.profile, encoding: .utf8)
        try """
        #!/bin/sh
        echo Welcome
        read line
        cat > '\(place.profile.path)' <<'JSON'
        \(same)
        JSON
        sleep 30
        """.write(to: place.script, atomically: true, encoding: .utf8)
        var probe = place.probe
        probe.timeout = 1.5
        #expect(await run(probe) == .failed)
    }

    @Test("Программа, которая не хочет закрываться, закрывается силой")
    func stubbornProcess() async throws {
        let place = try Place(body: "")
        try """
        #!/bin/sh
        echo $$ > '\(place.logs.path)/pid'
        trap '' TERM
        while true; do sleep 1; done
        """.write(to: place.script, atomically: true, encoding: .utf8)
        var probe = place.probe
        probe.timeout = 3
        probe.exitGrace = 0.5
        #expect(await run(probe) == .failed)
        let written = try #require(place.log("pid"))
        let pid = try #require(Int32(written.trimmingCharacters(in: .whitespacesAndNewlines)))
        #expect(kill(pid, 0) != 0)
    }

    @Test("Совсем свежий кэш Claude Code не перепишет, поэтому запуска нет")
    func youngCache() async throws {
        let place = try Place(fetchedAgo: 30, body: "")
        try """
        #!/bin/sh
        touch '\(place.logs.path)/started'
        """.write(to: place.script, atomically: true, encoding: .utf8)
        #expect(await run(place.probe) == .refreshed)
        #expect(place.log("started") == nil)
    }

    @Test("Программы нет: это сбой, а не падение")
    func missingBinary() async throws {
        let place = try Place(body: "")
        var probe = place.probe
        probe.binary = place.folder.url.appendingPathComponent("no-such-program")
        #expect(await run(probe) == .failed)
    }
}

@Suite("Сессии скрытого запуска не видны в списках")
struct UsageProbeHiddenTests {
    private let own = BorisPaths.usageProbeFolder.path
    private let utc = TimeZone(identifier: "UTC") ?? .current

    private func procStart(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = utc
        formatter.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        return formatter.string(from: date)
    }

    private func line(_ id: String, cwd: String?) -> String {
        let place = cwd.map { #""cwd":"\#($0)","# } ?? ""
        return #"{"type":"assistant","timestamp":"2026-11-05T12:00:00.000Z",\#(place)"entrypoint":"cli","message":{"id":"\#(id)","model":"claude-opus-5-5","usage":{"input_tokens":10,"output_tokens":1}}}"# + "\n"
    }

    @Test("Живая сессия из своей папки скрыта, а обычная рядом видна")
    func live() async throws {
        let folder = TempFolder()
        let pid = ProcessInfo.processInfo.processIdentifier
        let start = procStart(try #require(ProcessInspector.startTime(pid: pid)))
        let updated = Int(Date().timeIntervalSince1970 * 1000)
        folder.write("sessions/\(pid).json", #"{"sessionId":"probe","pid":\#(pid),"procStart":"\#(start)","cwd":"\#(own)","entrypoint":"cli","status":"busy","statusUpdatedAt":\#(updated)}"#)
        let scanner = RunScanner(paths: ClaudePaths(root: folder.url))
        let hidden = await scanner.scan(now: Date())
        #expect(hidden.sessions.isEmpty)
        #expect(WorkBuilder.build(world: hidden, runs: []).sessions.isEmpty)

        folder.write("sessions/\(pid).json", #"{"sessionId":"work","pid":\#(pid),"procStart":"\#(start)","cwd":"/x/proj","entrypoint":"cli","status":"busy","statusUpdatedAt":\#(updated)}"#)
        #expect(await scanner.scan(now: Date()).sessions.map(\.sessionId) == ["work"])
    }

    @Test("Запуск, убитый силой, не остаётся прерванной сессией")
    func killedProbe() async throws {
        let folder = TempFolder()
        let updated = Int(Date().timeIntervalSince1970 * 1000)
        // No such process: its file stayed behind, as after `kill -9`.
        folder.write("sessions/999999.json", #"{"sessionId":"probe","pid":999999,"procStart":"Thu Nov  5 10:00:00 2026","cwd":"\#(own)","entrypoint":"cli","status":"busy","statusUpdatedAt":\#(updated)}"#)
        let world = await RunScanner(paths: ClaudePaths(root: folder.url)).scan(now: Date())
        #expect(world.endedSessions.isEmpty)
        #expect(WorkBuilder.build(world: world, runs: []).sessions.isEmpty)
    }

    @Test("Лог из своей папки не появляется как сессия без файла процесса, даже если в нём нет cwd", arguments: [true, false])
    func unlisted(hasCwd: Bool) async {
        let folder = TempFolder()
        let scanner = RunScanner(paths: ClaudePaths(root: folder.url))
        _ = await scanner.scan(now: Date())
        try? await Task.sleep(for: .milliseconds(30))
        folder.write("projects/\(BorisPaths.usageProbeProject)/probe.jsonl", line("m1", cwd: hasCwd ? own : nil))
        await scanner.markDiscovery()
        let world = await scanner.scan(now: Date())
        #expect(!world.sessions.contains { $0.sessionId == "probe" })
    }

    @Test("Обычный лог без файла процесса при этом виден: проверка выше не пуста")
    func ordinaryUnlisted() async {
        let folder = TempFolder()
        let scanner = RunScanner(paths: ClaudePaths(root: folder.url))
        _ = await scanner.scan(now: Date())
        try? await Task.sleep(for: .milliseconds(30))
        folder.write("projects/other/work.jsonl", line("m1", cwd: "/x/proj"))
        await scanner.markDiscovery()
        #expect(await scanner.scan(now: Date()).sessions.contains { $0.sessionId == "work" })
    }

    @Test("Токены скрытых запусков не считаются")
    func tokens() async {
        let folder = TempFolder()
        folder.write("projects/\(BorisPaths.usageProbeProject)/probe.jsonl", line("m1", cwd: own))
        folder.write("projects/other/work.jsonl", line("m2", cwd: "/x/proj"))
        let index = TokenIndex(cacheFile: nil, timeZone: utc)
        await index.update(roots: [ClaudePaths(root: folder.url)])
        #expect(await index.records().map(\.sessionId) == ["work"])
    }

    @Test("Только своя папка считается своей", arguments: ["/x/usage-probe", "/x/proj", "", "usage-probe"])
    func onlyOwnFolder(path: String) {
        #expect(!BorisPaths.isUsageProbe(cwd: path))
    }

    @Test("Своя папка узнаётся и со слешем на конце")
    func ownFolder() {
        #expect(BorisPaths.isUsageProbe(cwd: own))
        #expect(BorisPaths.isUsageProbe(cwd: own + "/"))
        #expect(!BorisPaths.isUsageProbe(cwd: nil))
    }

    @Test("Имя папки логов строится так же, как у Claude Code")
    func projectName() {
        let name = BorisPaths.usageProbeProject
        #expect(name.hasSuffix("-usage-probe"))
        #expect(name.hasPrefix("-"))
        #expect(!name.contains("/"))
        #expect(!name.contains(" "))
        #expect(!name.contains("."))
    }
}

@Suite("Старое значение лимитов не пропадает")
struct UsageKeptTests {
    private func profile(fetchedAt: Date, percent: Int) -> String {
        #"{"oauthAccount":{"x":"y"},"cachedUsageUtilization":{"fetchedAtMs":\#(Int(fetchedAt.timeIntervalSince1970 * 1000)),"utilization":{"seven_day":{"utilization":\#(percent)}}}}"#
    }

    @Test("Файл сломался, исчез или лишился кэша: значение и его настоящий возраст остаются")
    func kept() async throws {
        let folder = TempFolder()
        let fetched = Date(timeIntervalSince1970: 1_793_880_000)
        let file = folder.write(".claude.json", profile(fetchedAt: fetched, percent: 34))
        let scanner = RunScanner(paths: ClaudePaths(root: folder.url))

        func usage() async -> UsageSnapshot? {
            await scanner.markUsageChanged()
            return await scanner.scan(now: Date()).usage
        }

        let first = try #require(await usage())
        #expect(first.windows.first?.percent == 34)
        #expect(first.fetchedAt == fetched)
        #expect(await scanner.scan(now: Date()).account == .signedIn)

        func rewrite(_ text: String) async throws {
            try? await Task.sleep(for: .milliseconds(20))
            try text.write(to: file, atomically: false, encoding: .utf8)
        }

        try await rewrite("{half a fi")
        #expect(await usage() == first)

        try await rewrite(#"{"oauthAccount":{"x":"y"}}"#)
        #expect(await usage() == first)

        try FileManager.default.removeItem(at: file)
        #expect(await usage() == first)

        // Fresh data replaces it as soon as there is any.
        let newer = fetched.addingTimeInterval(600)
        try await rewrite(profile(fetchedAt: newer, percent: 47))
        let fresh = try #require(await usage())
        #expect(fresh.windows.first?.percent == 47)
        #expect(fresh.fetchedAt == newer)
    }

    @Test("Вход пропал: чужие лимиты не остаются на экране как свои")
    func signedOut() async throws {
        let folder = TempFolder()
        let file = folder.write(".claude.json", profile(fetchedAt: Date(timeIntervalSince1970: 1_793_880_000), percent: 34))
        let scanner = RunScanner(paths: ClaudePaths(root: folder.url))
        await scanner.markUsageChanged()
        #expect(await scanner.scan(now: Date()).usage != nil)

        try? await Task.sleep(for: .milliseconds(20))
        try #"{"primaryApiKey":"k"}"#.write(to: file, atomically: false, encoding: .utf8)
        await scanner.markUsageChanged()
        let world = await scanner.scan(now: Date())
        #expect(world.account == .apiKey)
        #expect(world.usage == nil)
    }

    @Test("Сбой обновления не трогает то, что видят экраны")
    func failedRefresh() async throws {
        let folder = TempFolder()
        let fetched = Date().addingTimeInterval(-3 * 3600)
        let file = folder.write(".claude.json", profile(fetchedAt: fetched, percent: 34))
        let script = folder.write("fake-claude", "#!/bin/sh\nexit 1\n")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let scanner = RunScanner(paths: ClaudePaths(root: folder.url))
        await scanner.markUsageChanged()
        let before = await scanner.scan(now: Date()).usage

        let probe = UsageProbe(binary: script, folder: folder.url.appendingPathComponent("usage-probe"), profile: file, configFolder: nil)
        #expect(await Task.detached { probe.run() }.value == .failed)

        await scanner.markUsageChanged()
        let after = await scanner.scan(now: Date()).usage
        #expect(after == before)
        // Honest age: three hours, not «just now».
        let age = try #require(after?.staleAge(now: Date()))
        #expect(age > 2.9 * 3600 && age < 3.1 * 3600)
    }
}
