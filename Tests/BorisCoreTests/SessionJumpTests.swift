import Foundation
import Testing
@testable import BorisCore

/// The tests have no translation table, so the English source is what they see.
@Suite("Переход к сессии")
struct SessionJumpTests {
    private func plan(_ environment: WorkEnvironment?, cwd: String? = "/x/p", exists: Bool = true, owner: String? = nil) -> SessionJump {
        SessionJump.plan(environment: environment, sessionId: "abc-123", cwd: cwd, folderExists: exists, owner: owner)
    }

    @Test("VS Code: сначала окно проекта, потом ссылка на сессию") func vsCode() {
        guard case .link(let url, let folder) = plan(.vsCode, owner: "com.microsoft.VSCode") else {
            Issue.record("no link")
            return
        }
        #expect(url.absoluteString == "vscode://anthropic.claude-code/open?session=abc-123")
        #expect(folder?.absoluteString == "vscode://file/x/p")
    }

    @Test("Ссылка идёт в ту программу, которой принадлежит процесс") func ownerDecides() {
        guard case .link(let url, _) = plan(.vsCode, owner: "com.todesktop.230313mzl4w4u92") else {
            Issue.record("no link")
            return
        }
        #expect(url.scheme == "cursor")
        guard case .link(let insiders, _) = plan(.vsCode, owner: "com.microsoft.VSCodeInsiders") else {
            Issue.record("no link")
            return
        }
        #expect(insiders.scheme == "vscode-insiders")
    }

    @Test("Сессия Cursor без живого процесса: ссылка Cursor") func cursorWithoutOwner() {
        guard case .link(let url, _) = plan(.cursor) else {
            Issue.record("no link")
            return
        }
        #expect(url.absoluteString == "cursor://anthropic.claude-code/open?session=abc-123")
    }

    @Test("Редактор без ссылки: на передний план и идентификатор в буфер") func unknownEditor() {
        #expect(plan(.vsCode, owner: "com.exafunction.windsurf") == .activateOwnerAndCopyId)
    }

    @Test("Папки проекта нет: ссылка не поможет") func folderGone() {
        #expect(plan(.vsCode, exists: false) == .folderGone)
        #expect(plan(.vsCode, cwd: nil, exists: false) != .folderGone)
    }

    @Test("Терминал: окно по дереву процессов, иначе само приложение") func terminal() {
        #expect(plan(.terminal, owner: "com.apple.Terminal") == .activateOwner)
        #expect(plan(.terminal) == .openTerminal)
        #expect(plan(.terminal, cwd: "/gone", exists: false, owner: "com.apple.Terminal") == .activateOwner)
    }

    @Test("Claude Desktop и Cowork: открывается приложение") func desktop() {
        #expect(plan(.claudeDesktop) == .openApp(bundleId: "com.anthropic.claudefordesktop"))
        #expect(plan(.cowork) == .openApp(bundleId: "com.anthropic.claudefordesktop"))
        #expect(plan(.chat) == .openApp(bundleId: "com.anthropic.claudefordesktop"))
    }

    @Test("У сессии без окна честно нечего открыть") func noWindow() {
        #expect(plan(.program) == .noWindow)
        #expect(plan(.insideClaude) == .noWindow)
        #expect(plan(.remote(host: "server")) == .noWindow)
        #expect(plan(nil) == .noWindow)
        #expect(plan(nil, owner: "com.apple.Terminal") == .activateOwner)
    }

    @Test("Надпись на кнопке называет среду") func titles() {
        #expect(SessionJump.title(.terminal) == "Open terminal")
        #expect(SessionJump.title(.vsCode) == "Open in VS Code")
        #expect(SessionJump.title(.cursor) == "Open in Cursor")
        #expect(SessionJump.title(.cowork) == "Open Claude Desktop")
        #expect(SessionJump.title(.program) == "Open session")
    }
}
