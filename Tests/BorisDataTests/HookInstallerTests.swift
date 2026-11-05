import Foundation
import BorisCore
import Testing
@testable import BorisData

@Suite("Установка хуков")
struct HookInstallerTests {
    private let plan = HookInstaller.Plan(helperPath: "/Users/x y/Applications/Boris.app/Contents/MacOS/boris-hook", permissions: false, permissionWait: 30)
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
        #expect(HookInstaller.status(at: file, plan: plan) == .installed)

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
        #expect(HookInstaller.status(at: file, plan: plan) == .installed)
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
        #expect(HookInstaller.status(["disableAllHooks": true], plan: plan) == .disabledByPolicy)
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

    @Test("Предпросмотр показывает только добавляемое") func previewLines() throws {
        let folder = TempFolder()
        let file = folder.write("settings.json", others)
        let lines = try HookInstaller.preview(at: file, plan: plan)
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
