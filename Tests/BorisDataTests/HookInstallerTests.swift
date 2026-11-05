import Foundation
import BorisCore
import Testing
@testable import BorisData

@Suite("Установка хуков")
struct HookInstallerTests {
    private let plan = HookInstaller.Plan(helperPath: "/Users/x y/Applications/Boris.app/Contents/MacOS/boris-hook", permissions: false, permissionWait: 30)
    private let noPolicy = ManagedSettings(folder: URL(fileURLWithPath: "/nonexistent"), profiles: [])
    private let others = """
    {
      "model": "opus",
      "permissions": { "allow": ["Bash(ls)"] },
      "hooks": {
        "PreToolUse": [ { "matcher": "Bash", "hooks": [ { "type": "command", "command": "/usr/local/bin/other" } ] } ],
        "Stop": [ { "hooks": [ { "type": "command", "command": "say done" } ] } ]
      }
    }

    """

    private func json(_ url: URL) throws -> NSDictionary {
        try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! NSDictionary
    }

    @Test("Чужие хуки на месте после установки и удаления, файл побайтно прежний") func restoresExactly() throws {
        let folder = TempFolder()
        let file = folder.write("settings.json", others)
        let original = try Data(contentsOf: file)
        try HookInstaller.install(at: file, plan: plan)

        let installed = try json(file) as! [String: Any]
        #expect(installed["model"] as? String == "opus")
        let hooks = installed["hooks"] as! [String: Any]
        let pre = hooks["PreToolUse"] as! [[String: Any]]
        #expect(pre.count == 2)
        #expect(pre[0]["matcher"] as? String == "Bash")
        #expect(((pre[0]["hooks"] as! [[String: Any]])[0]["command"] as? String) == "/usr/local/bin/other")
        #expect(HookInstaller.status(at: file, plan: plan, managed: noPolicy) == .installed)

        try HookInstaller.uninstall(at: file)
        #expect(try Data(contentsOf: file) == original)
        #expect(!FileManager.default.fileExists(atPath: file.path + ".boris-backup"))
    }

    @Test("Резервная копия рядом и не перезаписывается при переустановке") func backupKept() throws {
        let folder = TempFolder()
        let file = folder.write("settings.json", others)
        let original = try Data(contentsOf: file)
        try HookInstaller.install(at: file, plan: plan)
        try HookInstaller.install(at: file, plan: plan)
        #expect(try Data(contentsOf: URL(fileURLWithPath: file.path + ".boris-backup")) == original)
    }

    @Test("Повторная установка не дублирует записи") func noDuplicates() throws {
        let folder = TempFolder()
        let file = folder.write("settings.json", "{}")
        try HookInstaller.install(at: file, plan: plan)
        try HookInstaller.install(at: file, plan: plan)
        let hooks = try json(file)["hooks"] as! [String: Any]
        #expect((hooks["Stop"] as! [Any]).count == 1)
        #expect(HookInstaller.status(at: file, plan: plan, managed: noPolicy) == .installed)
    }

    @Test("Если пользователь менял файл, удаляются только наши записи") func keepsLaterChanges() throws {
        let folder = TempFolder()
        let file = folder.write("settings.json", others)
        try HookInstaller.install(at: file, plan: plan)
        var edited = try json(file) as! [String: Any]
        edited["model"] = "sonnet"
        try JSONSerialization.data(withJSONObject: edited).write(to: file)
        try HookInstaller.uninstall(at: file)
        let result = try json(file) as! [String: Any]
        #expect(result["model"] as? String == "sonnet")
        let text = try String(contentsOf: file, encoding: .utf8)
        #expect(!text.contains("boris-hook"))
        #expect(text.contains("/usr/local/bin/other"))
    }

    @Test("Некорректный JSON: ничего не пишем") func invalidJSON() throws {
        let folder = TempFolder()
        let file = folder.write("settings.json", "{ not json")
        #expect(throws: HookInstaller.Failure.invalidSettings) { try HookInstaller.install(at: file, plan: plan) }
        #expect(throws: HookInstaller.Failure.invalidSettings) { try HookInstaller.preview(at: file, plan: plan) }
        #expect(try String(contentsOf: file, encoding: .utf8) == "{ not json")
    }

    @Test("Файла не было: появляется и исчезает") func noFileBefore() throws {
        let folder = TempFolder()
        let file = folder.url.appendingPathComponent("settings.json")
        try HookInstaller.install(at: file, plan: plan)
        #expect(FileManager.default.fileExists(atPath: file.path))
        try HookInstaller.uninstall(at: file)
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test("Состояния: нет записей, устарели, отключены политикой") func statuses() throws {
        #expect(HookInstaller.status([:], plan: plan) == .notInstalled)
        let installed = HookInstaller.merged([:], plan: plan)
        #expect(HookInstaller.status(installed, plan: plan) == .installed)
        var moved = plan
        moved.helperPath = "/other/boris-hook"
        #expect(HookInstaller.status(installed, plan: moved) == .outdated)
        var withPermissions = plan
        withPermissions.permissions = true
        #expect(HookInstaller.status(installed, plan: withPermissions) == .outdated)
        #expect(HookInstaller.status(["disableAllHooks": true], plan: plan) == .disabledInSettings)
    }

    @Test("Без разрешений синхронного хука нет, с ними есть и только он без async") func permissionHook() throws {
        let observe = HookInstaller.merged([:], plan: plan)["hooks"] as! [String: Any]
        #expect(observe["PermissionRequest"] == nil)
        for (_, value) in observe {
            let hook = ((value as! [[String: Any]])[0]["hooks"] as! [[String: Any]])[0]
            #expect(hook["async"] as? Bool == true)
        }
        var withPermissions = plan
        withPermissions.permissions = true
        let hooks = HookInstaller.merged([:], plan: withPermissions)["hooks"] as! [String: Any]
        let hook = ((hooks["PermissionRequest"] as! [[String: Any]])[0]["hooks"] as! [[String: Any]])[0]
        #expect(hook["async"] == nil)
        #expect(hook["timeout"] as? Int == 35)
        #expect((hook["command"] as? String)?.contains("--permission 30") == true)
    }

    @Test("Команда безопасна к пробелам и кавычкам в пути и молчит без файла") func commandQuoting() throws {
        var odd = plan
        odd.helperPath = "/tmp/it's a dir/boris-hook"
        let command = HookInstaller.command(odd, permission: false)
        let run = Process()
        run.executableURL = URL(fileURLWithPath: "/bin/sh")
        run.arguments = ["-c", command]
        let out = Pipe()
        run.standardOutput = out
        run.standardError = out
        try run.run()
        run.waitUntilExit()
        #expect(run.terminationStatus == 0)
        #expect(out.fileHandleForReading.readDataToEndOfFile().isEmpty)
    }

    @Test("Значение неожиданного вида не затирается: файл не трогаем", arguments: [
        #"{"hooks": ["strange"]}"#,
        #"{"hooks": null}"#,
        #"{"hooks": {"Stop": "say done"}}"#,
        #"{"hooks": {"PreToolUse": {"matcher": "Bash"}}}"#,
        #"[1, 2]"#,
    ])
    func unexpectedShape(text: String) throws {
        let folder = TempFolder()
        let file = folder.write("settings.json", text)
        #expect(throws: HookInstaller.Failure.invalidSettings) { try HookInstaller.install(at: file, plan: plan) }
        #expect(throws: HookInstaller.Failure.invalidSettings) { try HookInstaller.uninstall(at: file) }
        #expect(HookInstaller.status(at: file, plan: plan, managed: noPolicy) == .unreadable)
        #expect(try String(contentsOf: file, encoding: .utf8) == text)
        #expect(!FileManager.default.fileExists(atPath: file.path + ".boris-backup"))
    }

    @Test("Незнакомое событие странного вида остаётся как было") func unknownEventKept() throws {
        let folder = TempFolder()
        let text = #"{"hooks":{"SomeFutureEvent":"strange"}}"#
        let file = folder.write("settings.json", text)
        let original = try Data(contentsOf: file)
        try HookInstaller.install(at: file, plan: plan)
        #expect(try String(contentsOf: file, encoding: .utf8).contains("strange"))
        try HookInstaller.uninstall(at: file)
        #expect(try Data(contentsOf: file) == original)
    }

    @Test("Файл есть, но прочитать его нельзя: не принимаем за пустой") func unreadableFile() throws {
        let folder = TempFolder()
        let file = folder.write("settings.json", others)
        let manager = FileManager.default
        try manager.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.path)
        defer { try? manager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path) }
        #expect(throws: HookInstaller.Failure.invalidSettings) { try HookInstaller.install(at: file, plan: plan) }
        #expect(HookInstaller.status(at: file, plan: plan, managed: noPolicy) == .unreadable)
        try manager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        #expect(try String(contentsOf: file, encoding: .utf8) == others)
    }

    @Test("Настройки по ссылке: ссылка остаётся ссылкой, файл за ней возвращается побайтно") func symlink() throws {
        let folder = TempFolder()
        let target = folder.write("dotfiles/claude-settings.json", others)
        let original = try Data(contentsOf: target)
        let link = folder.url.appendingPathComponent("settings.json")
        let manager = FileManager.default
        try manager.createSymbolicLink(at: link, withDestinationURL: target)

        try HookInstaller.install(at: link, plan: plan)
        #expect(try manager.destinationOfSymbolicLink(atPath: link.path) == target.path)
        #expect(try String(contentsOf: target, encoding: .utf8).contains("boris-hook"))
        #expect(HookInstaller.status(at: link, plan: plan, managed: noPolicy) == .installed)

        try HookInstaller.uninstall(at: link)
        #expect(try manager.destinationOfSymbolicLink(atPath: link.path) == target.path)
        #expect(try Data(contentsOf: target) == original)
    }

    @Test("Ссылка в никуда: не заменяем её обычным файлом") func danglingSymlink() throws {
        let folder = TempFolder()
        let link = folder.url.appendingPathComponent("settings.json")
        let missing = folder.url.appendingPathComponent("gone/settings.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: missing)
        #expect(throws: HookInstaller.Failure.invalidSettings) { try HookInstaller.install(at: link, plan: plan) }
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == missing.path)
    }

    @Test("Права на файл сохраняются") func permissionsKept() throws {
        let folder = TempFolder()
        let file = folder.write("settings.json", others)
        let manager = FileManager.default
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        try HookInstaller.install(at: file, plan: plan)
        #expect(try manager.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int == 0o600)
        #expect(try manager.attributesOfItem(atPath: file.path + ".boris-backup")[.posixPermissions] as? Int == 0o600)
        try HookInstaller.uninstall(at: file)
        #expect(try manager.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int == 0o600)
    }

    @Test("Второе подключение после правок: файл возвращается к состоянию перед ним") func secondConnection() throws {
        let folder = TempFolder()
        let file = folder.write("settings.json", others)
        try HookInstaller.install(at: file, plan: plan)
        var edited = try json(file) as! [String: Any]
        edited["model"] = "sonnet"
        try JSONSerialization.data(withJSONObject: edited).write(to: file)
        try HookInstaller.uninstall(at: file)

        let beforeSecond = try Data(contentsOf: file)
        try HookInstaller.install(at: file, plan: plan)
        try HookInstaller.uninstall(at: file)
        #expect(try Data(contentsOf: file) == beforeSecond)
        #expect(!FileManager.default.fileExists(atPath: file.path + ".boris-backup"))
    }

    @Test("Файла не было, а старая копия осталась: она не возвращается") func staleBackupWithoutFile() throws {
        let folder = TempFolder()
        let file = folder.url.appendingPathComponent("settings.json")
        folder.write("settings.json.boris-backup", others)
        try HookInstaller.install(at: file, plan: plan)
        try HookInstaller.uninstall(at: file)
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test("Починка не портит копию: отключение всё равно возвращает исходное") func repairKeepsBackup() throws {
        let folder = TempFolder()
        let file = folder.write("settings.json", others)
        let original = try Data(contentsOf: file)
        try HookInstaller.install(at: file, plan: plan)
        // Part of our entries is gone, as after another program has edited the file.
        var settings = try json(file) as! [String: Any]
        var hooks = settings["hooks"] as! [String: Any]
        hooks["Notification"] = nil
        settings["hooks"] = hooks
        try JSONSerialization.data(withJSONObject: settings).write(to: file)
        #expect(HookInstaller.status(at: file, plan: plan, managed: noPolicy) == .outdated)

        try HookInstaller.install(at: file, plan: plan)
        #expect(HookInstaller.status(at: file, plan: plan, managed: noPolicy) == .installed)
        try HookInstaller.uninstall(at: file)
        #expect(try Data(contentsOf: file) == original)
    }

    @Test("Отключение, когда наших записей нет: файл не трогаем") func nothingToRemove() throws {
        let folder = TempFolder()
        let text = "{ \"model\":   \"opus\" }"
        let file = folder.write("settings.json", text)
        #expect(try HookInstaller.previewRemoval(at: file).lines.isEmpty)
        try HookInstaller.uninstall(at: file)
        #expect(try String(contentsOf: file, encoding: .utf8) == text)
    }

    @Test("Побайтный возврат и там, где исходное необычно", arguments: ["", "{}", #"{"hooks":{}}"#, #"{"hooks":{"Stop":[]},"statusLine":{"type":"command","command":"my-line"}}"#])
    func oddOriginals(text: String) throws {
        let folder = TempFolder()
        let file = folder.write("settings.json", text)
        try HookInstaller.install(at: file, plan: plan)
        try HookInstaller.uninstall(at: file)
        #expect(try String(contentsOf: file, encoding: .utf8) == text)
    }

    @Test("Занятая статус-строка не меняется") func statusLineKept() throws {
        let folder = TempFolder()
        let file = folder.write("settings.json", #"{"statusLine":{"type":"command","command":"my-line"}}"#)
        try HookInstaller.install(at: file, plan: plan)
        let installed = try json(file) as! [String: Any]
        #expect((installed["statusLine"] as? [String: Any])?["command"] as? String == "my-line")
    }

    @Test("SubagentStart подключается и не ждёт") func subagentStart() throws {
        let hooks = HookInstaller.merged([:], plan: plan)["hooks"] as! [String: Any]
        let hook = ((hooks["SubagentStart"] as! [[String: Any]])[0]["hooks"] as! [[String: Any]])[0]
        #expect(hook["async"] as? Bool == true)
    }

    @Test("Предпросмотр предупреждает о смене оформления и ничего не пишет") func previewReformats() throws {
        let folder = TempFolder()
        let file = folder.write("settings.json", others)
        let before = try Data(contentsOf: file)
        #expect(try HookInstaller.preview(at: file, plan: plan).reformats)
        #expect(try Data(contentsOf: file) == before)
        #expect(!FileManager.default.fileExists(atPath: file.path + ".boris-backup"))

        let tidy = folder.write("tidy.json", String(decoding: try HookInstaller.encode(["model": "opus"]), as: UTF8.self))
        #expect(try !HookInstaller.preview(at: tidy, plan: plan).reformats)
        let missing = folder.url.appendingPathComponent("missing.json")
        let lines = try HookInstaller.preview(at: missing, plan: plan)
        #expect(!lines.reformats)
        #expect(lines.lines.allSatisfy { $0.hasPrefix("+") || $0.hasPrefix("- {") || $0.hasPrefix("- }") })
    }

    @Test("Предпросмотр показывает только добавляемое") func previewLines() throws {
        let folder = TempFolder()
        let file = folder.write("settings.json", others)
        let lines = try HookInstaller.preview(at: file, plan: plan).lines
        #expect(lines.contains { $0.hasPrefix("+") && $0.contains("boris-hook") })
        #expect(!lines.contains { $0.contains("/usr/local/bin/other") })
    }
}

@Suite("Точный расход токенов запуска")
struct RunTokensTests {
    @Test("Сумма по агентам: дубли сообщения считаются один раз") func runTokens() {
        let folder = TempFolder()
        let message = { (id: String, input: Int, out: Int) in
            #"{"type":"assistant","message":{"id":"\#(id)","model":"m","usage":{"input_tokens":\#(input),"output_tokens":\#(out),"cache_read_input_tokens":100,"cache_creation_input_tokens":10}}}"#
        }
        folder.write("agent-a.jsonl", [#"{"type":"user","message":{"content":"p"}}"#, message("m1", 5, 1), message("m1", 5, 50), message("m2", 7, 20)].joined(separator: "\n"))
        folder.write("agent-b.jsonl", message("m3", 1, 2))
        folder.write("journal.jsonl", "{}")
        folder.write("agent-a.meta.json", "{}")
        // By hand: inputs 5+7+1, outputs 50+20+2, cache read 100*3, cache write 10*3.
        let total = AgentDetailReader.runTokens(runDir: folder.url)
        #expect(total.input == 13)
        #expect(total.output == 72)
        #expect(total.cacheRead == 300)
        #expect(total.cacheWrite == 30)
    }
}
