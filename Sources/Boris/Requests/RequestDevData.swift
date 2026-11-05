#if DEBUG
import BorisCore
import BorisData
import Foundation
import SwiftUI

/// Made-up requests for looking at screens. Nothing here comes from real sessions.
@MainActor
enum RequestDevData {
    static func fill(_ model: AppModel, data: DevData) {
        guard data != .empty else {
            model.hooks.showForSnapshot(status: .installed)
            return
        }
        let long = data == .long
        let now = Date()
        func asked(_ ago: TimeInterval) -> (Date, Date) {
            (now.addingTimeInterval(-ago), now.addingTimeInterval(120 - ago))
        }
        let times = [asked(18), asked(5), asked(2520)]
        let command = long
            ? "npm run migrate -- --env=staging --from=2026_10_01_000000 --to=latest --lock-timeout=120 && npm run seed:verify -- --strict --report=./tmp/seed-report.json && rm -rf ./tmp/old-reports ./tmp/older-reports"
            : "npm run migrate"
        let open = [
            PendingPermission(session: "a1", tool: "Bash", command: command, content: .command(command, unsandboxed: long), project: long ? "a-very-long-project-name-that-nobody-would-ever-want-to-type-by-hand-more-than-once" : "shop-api", mode: "default", askedAt: times[0].0, deadline: times[0].1),
            PendingPermission(session: "b1", agent: "h1", agentType: "code-reviewer", tool: "Edit", content: .file(path: long ? "/x/boris/src/a-folder-with-a-rather-long-name/and-another-one-inside-it/and-one-more-for-good-measure/auth.swift" : "/x/boris/src/auth.swift", lines: editLines(long: long), whole: false, everyOccurrence: long), project: "boris", cwd: "/x/boris", mode: "default", askedAt: times[1].0, deadline: times[1].1),
        ]
        let expired = [
            PendingPermission(session: "d1", tool: "Bash", content: .command("make deploy", unsandboxed: false), project: "landing", askedAt: times[2].0, deadline: times[2].1),
        ]
        model.hooks.showForSnapshot(status: .installed)
        model.hooks.showRequestsForSnapshot(open: open, expired: expired, decisions: decisions(now: now, long: long))
    }

    private static func editLines(long: Bool) -> [RequestDiffLine] {
        var lines = [
            RequestDiffLine(added: false, text: "if try verifySignature(token) {"),
            RequestDiffLine(added: false, text: "    guard !token.isExpired else { return .expired }"),
            RequestDiffLine(added: true, text: "guard !token.isExpired else { return .expired }"),
            RequestDiffLine(added: true, text: "guard try verifySignature(token) else { return .invalid }"),
        ]
        if long {
            lines += (1...40).map { RequestDiffLine(added: true, text: "let generatedValueNumber\($0) = makeSomethingVeryLongAndUnpleasantToReadWithoutWrappingItAtAll(\($0))") }
        }
        return lines
    }

    private static func decisions(now: Date, long: Bool) -> [RequestDecision] {
        func row(_ minutes: TimeInterval, _ project: String, _ environment: String, _ agent: String?, _ brief: RequestBrief, _ outcome: RequestOutcome, _ place: RequestPlace, _ waited: TimeInterval) -> RequestDecision {
            RequestDecision(id: UUID(), at: now.addingTimeInterval(-minutes * 60), project: project, environment: environment, agentType: agent, isMainAgent: agent == nil, brief: brief, outcome: outcome, place: place, waited: waited)
        }
        let longProject = "a-very-long-project-name-that-nobody-would-ever-want-to-type-by-hand-more-than-once"
        return [
            row(1, "boris", L("Terminal"), "code-reviewer", RequestBrief(tool: "Bash", kind: .command), .allowed, .notch, 8),
            row(2, "landing", "Claude Desktop", nil, RequestBrief(tool: "Write", kind: .file, fileName: long ? "a-file-with-a-name-so-long-that-it-cannot-possibly-fit-anywhere-on-one-line.html" : "index.html"), .allowed, .session, 120),
            row(3, "landing", "Claude Desktop", nil, RequestBrief(tool: "ExitPlanMode", kind: .plan), .planApproved, .window, 106),
            row(4, long ? longProject : "shop-api", "VS Code", nil, RequestBrief(tool: "Bash", kind: .command), .denied, .mini, 19),
            row(5, "boris", L("Terminal"), nil, RequestBrief(tool: "AskUserQuestion", kind: .questions, questions: 1), .answered, .hotKey, 44),
            row(6, "shop-api", L("Terminal"), nil, RequestBrief(tool: "Bash", kind: .command), .expired, .session, 120),
            row(7, "shop-api", "VS Code", nil, RequestBrief(tool: "Edit", kind: .file, fileName: "orders.sql"), .closedInClaude, .session, 37),
        ]
    }
}

/// Every kind of card side by side, as on the design board.
struct RequestCardsSheet: View {
    @Bindable var model: AppModel

    private func request(_ tool: String, _ content: RequestContent, project: String = "shop-api", agent: String? = nil) -> PendingPermission {
        let now = Date()
        return PendingPermission(session: "a1", agent: agent, agentType: agent == nil ? nil : "code-reviewer", tool: tool, content: content, project: project, cwd: "/x/\(project)", mode: "default", askedAt: now.addingTimeInterval(-18), deadline: now.addingTimeInterval(102))
    }

    private var longCommand: String {
        "npm run migrate -- --env=staging --from=2026_10_01_000000 --to=latest --lock-timeout=120 && npm run seed:verify -- --strict --report=./tmp/seed-report.json"
    }

    private var questions: [RequestQuestion] {
        [
            RequestQuestion(text: "Which database should we use?", options: [.init(label: "PostgreSQL", detail: "Runs as a separate server"), .init(label: "SQLite")]),
            RequestQuestion(text: "What should be set up right away?", multiple: true, options: [.init(label: "Migrations"), .init(label: "Backups")]),
        ]
    }

    private var lines: [RequestDiffLine] {
        [
            RequestDiffLine(added: false, text: "if try verifySignature(token) {"),
            RequestDiffLine(added: true, text: "guard try verifySignature(token) else { return .invalid }"),
        ]
    }

    var body: some View {
        let cards: [PendingPermission] = [
            request("Bash", .command("npm run migrate", unsandboxed: false)),
            request("Bash", .command(longCommand, unsandboxed: true)),
            request("Edit", .file(path: "/x/boris/src/auth.swift", lines: lines, whole: false, everyOccurrence: true), project: "boris", agent: "h1"),
            request("Write", .file(path: "/elsewhere/notes.txt", lines: [RequestDiffLine(added: true, text: "First line")], whole: true, everyOccurrence: false)),
            request("AskUserQuestion", .questions(questions)),
            request("ExitPlanMode", .plan("1. Add the table `orders_archive`.\n2. Move orders older than a year.\n3. **Check** the counts before and after.\n4. Remove the moved rows from `orders`.\n5. One more step.\n6. And another one.\n7. The last one.")),
            request("mcp__tracker__create", .other("{\n  \"title\" : \"Fix the login\"\n}")),
            request("Write", .unreadable("first part of something very long…")),
        ]
        let expired = ExpiredRequest(request("Bash", .command("make deploy", unsandboxed: false)))
        let cowork = WorkSession(id: "c1", environment: .cowork, title: "Quarterly report", state: .waiting, root: WorkNode(id: "c1", kind: .main, state: .waiting))
        let session = WorkSession(id: "a1", environment: .vsCode, cwd: "/x/shop-api", state: .waiting, root: WorkNode(id: "a1", kind: .main, state: .waiting))
        ScrollView {
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(420), spacing: 16, alignment: .top), count: 3), alignment: .leading, spacing: 16) {
                ForEach(cards) { RequestCard(model: model, request: $0, surface: .window) }
                DeniedCardPreview(model: model, request: request("Bash", .command("npm run migrate", unsandboxed: false)))
                RequestNoticeCard(model: model, row: .expired(expired))
                RequestNoticeCard(model: model, row: .waiting(session))
                RequestNoticeCard(model: model, row: .waiting(cowork))
            }
            .padding(20)
        }
        .frame(height: 1560)
        .background(Palette.desk)
        .foregroundStyle(Palette.text1)
    }
}

/// A card with the reason form already open.
private struct DeniedCardPreview: View {
    @Bindable var model: AppModel
    var request: PendingPermission

    var body: some View {
        RequestCard(model: model, request: request, surface: .window)
            .onAppear { model.hooks.updateDraft(request.id) { $0.denying = true } }
    }
}
#endif
