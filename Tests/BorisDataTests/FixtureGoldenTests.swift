import Foundation
import BorisCore
import Testing
@testable import BorisData

/// Runs the full pipeline over anonymized real runs and compares it with expected.json,
/// which scripts/make-fixtures.py computes separately in Python.
@Suite("Эталон на реальных запусках")
struct FixtureGoldenTests {
    private func allRuns() async throws -> (states: [RunState], world: WorldSnapshot) {
        let folder = TempFolder()
        let paths = try Fixtures.world(into: folder)
        var config = RunScanner.Config()
        config.window = .infinity
        let scanner = RunScanner(paths: paths, config: config)
        // Copying the fixtures touches their folders, so "now" has to be later than the copy.
        let world = await scanner.scan(now: Date().addingTimeInterval(60))
        var tracker = RunTracker()
        // No process is alive in the fixtures, so every run without a result has lost its owner.
        let states = tracker.resolve(world) { _ in nil }
        return (states, world)
    }

    @Test("Эталон существует и покрывает все запуски") func expectedExists() throws {
        let expected = try Fixtures.expected()
        let manifest = try Fixtures.manifest()
        #expect(expected.runs == manifest.runs.count)
        #expect(expected.runs > 100)
    }

    @Test("Гистограмма статусов совпадает с независимым подсчётом") func statusHistogram() async throws {
        let expected = try Fixtures.expected()
        let (states, _) = try await allRuns()
        var histogram: [String: Int] = [:]
        for state in states { histogram[state.status.key, default: 0] += 1 }
        #expect(histogram == expected.status)
    }

    @Test("Причины падений совпадают, большинство это лимит") func failureClasses() async throws {
        let expected = try Fixtures.expected()
        let (_, world) = try await allRuns()
        var histogram: [String: Int] = [:]
        for run in world.runs {
            for agent in run.agents where agent.state == .failed {
                histogram[(agent.failure?.failureClass ?? .unknown).rawValue, default: 0] += 1
            }
        }
        #expect(histogram == expected.failureClass)
        let total = histogram.values.reduce(0, +)
        #expect(Double(histogram["limit"] ?? 0) / Double(total) > 0.9)
    }

    @Test("Контекст совпадает с tokens из итога в пределах 1%") func contextMatchesFinalTokens() throws {
        let folder = TempFolder()
        let paths = try Fixtures.world(into: folder)
        var compared = 0
        var close = 0
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: paths.projects, includingPropertiesForKeys: nil) else { return }
        for case let url as URL in walker where url.pathExtension == "json" && url.deletingLastPathComponent().lastPathComponent == "workflows" {
            guard let report = FinalReader.read(url) else { continue }
            let runDir = url.deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("subagents/workflows").appendingPathComponent(url.deletingPathExtension().lastPathComponent)
            for entry in report.entries where (entry.tokens ?? 0) > 0 && entry.state == "done" {
                guard let id = entry.agentId, let tokens = entry.tokens else { continue }
                let file = runDir.appendingPathComponent("agent-\(id).jsonl")
                guard fm.fileExists(atPath: file.path), let usage = TranscriptReader.tail(file).usage else { continue }
                compared += 1
                if abs(Double(usage.context) - Double(tokens)) <= Double(tokens) * 0.01 + 5 { close += 1 }
            }
        }
        #expect(compared > 20)
        #expect(Double(close) / Double(compared) > 0.85)
    }

    @Test("У остановленных запусков найден вызов TaskStop") func stopCalls() async throws {
        let (states, _) = try await allRuns()
        let stopped = states.filter { $0.status == .stopped }
        #expect(stopped.count == 7)
        let allByClaude = stopped.allSatisfy { $0.stoppedByClaude }
        #expect(allByClaude)
    }

    @Test("Запуски разложены по фазам и названы") func phasesAndNames() async throws {
        let (states, world) = try await allRuns()
        #expect(states.filter { !$0.name.hasPrefix("wf_") }.count > 80)
        #expect(world.runs.filter { !$0.plannedPhases.isEmpty }.count > 50)
    }

    @Test("Нет ложных сообщений о смене формата") func noFalseFormatAlarm() async throws {
        let (_, world) = try await allRuns()
        #expect(world.formatIssues.isEmpty)
    }
}

@Suite("Статистика: прошлые данные")
struct HistoryTests {
    @Test("Восстановление считает итоги, а не запуски без итога") func restore() throws {
        let folder = TempFolder()
        let paths = try Fixtures.world(into: folder)
        let items = HistoryReader.finishedRuns(paths: paths, since: .distantPast)
        let expected = try Fixtures.expected()
        var histogram: [String: Int] = [:]
        for item in items { histogram[item.run.status.key, default: 0] += 1 }
        var withoutInterrupted = expected.status
        withoutInterrupted["interrupted"] = nil
        #expect(histogram == withoutInterrupted)
    }

    @Test("Старше периода не учитывается") func window() throws {
        let folder = TempFolder()
        let paths = try Fixtures.world(into: folder)
        let items = HistoryReader.finishedRuns(paths: paths, since: Date().addingTimeInterval(3600))
        #expect(items.isEmpty)
    }
}
