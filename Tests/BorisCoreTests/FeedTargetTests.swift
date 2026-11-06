@testable import BorisCore
import Foundation
import Testing

@Suite("Куда ведёт сбой")
struct FeedTargetTests {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func entry(_ id: String, at seconds: TimeInterval?, agent: String? = nil) -> FeedEntry {
        FeedEntry(sessionId: "s", agentId: agent, item: .step(ActivityStep(id: id, tool: "Bash", kind: .shell, input: ToolInput(), state: .done, startedAt: seconds.map { start.addingTimeInterval($0) })))
    }

    private func id(_ step: String, agent: String? = nil) -> String {
        "s/\(agent ?? "")/\(step)"
    }

    @Test("Упавший вызов находится по своему номеру")
    func exactCall() {
        let entries = [entry("a", at: 1), entry("bad", at: 2, agent: "x"), entry("c", at: 3)]
        #expect(SessionFeed.place(ofFailure: FeedTarget(stepId: "bad", at: start.addingTimeInterval(100)), in: entries) == id("bad", agent: "x"))
    }

    @Test("Без вызова это последняя запись до сбоя, например при ошибке API")
    func nearestBefore() {
        let entries = [entry("a", at: 1), entry("b", at: 2), entry("c", at: 30)]
        #expect(SessionFeed.place(ofFailure: FeedTarget(stepId: "api-error", at: start.addingTimeInterval(10)), in: entries) == id("b"))
    }

    @Test("Лента начинается позже сбоя: идти некуда")
    func tooOld() {
        let entries = [entry("a", at: 100)]
        #expect(SessionFeed.place(ofFailure: FeedTarget(stepId: "gone", at: start), in: entries) == nil)
        #expect(SessionFeed.place(ofFailure: FeedTarget(stepId: "gone", at: start), in: []) == nil)
    }

    @Test("Запись без времени не считается за раннюю")
    func noTime() {
        let entries = [entry("a", at: 1), entry("b", at: nil)]
        #expect(SessionFeed.place(ofFailure: FeedTarget(stepId: "x", at: start.addingTimeInterval(5)), in: entries) == id("a"))
    }
}
