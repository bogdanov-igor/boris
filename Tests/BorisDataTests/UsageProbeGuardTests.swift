import Foundation
import Testing

@Suite("Настоящий Claude Code не запускается из отладочных сборок и тестов")
struct UsageProbeGuardTests {
    private var sources: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources")
    }

    private func swiftFiles() -> [URL] {
        let walker = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)
        return (walker?.allObjects as? [URL] ?? []).filter { $0.pathExtension == "swift" }
    }

    @Test("Тесты не ищут настоящую программу: у них только свои маленькие скрипты")
    func testsNeverLookForIt() {
        let tests = sources.deletingLastPathComponent().appendingPathComponent("Tests")
        let walker = FileManager.default.enumerator(at: tests, includingPropertiesForKeys: nil)
        let files = (walker?.allObjects as? [URL] ?? []).filter { $0.pathExtension == "swift" && $0.lastPathComponent != "UsageProbeGuardTests.swift" }
        #expect(!files.isEmpty)
        let lookers = files.filter { ((try? String(contentsOf: $0, encoding: .utf8)) ?? "").contains("ClaudeCodeBinary") }
        #expect(lookers.isEmpty, "\(lookers.map(\.lastPathComponent))")
    }

    @Test("Запуск и поиск программы есть только в одном месте, и только вне DEBUG")
    func onlyInRelease() throws {
        let callers = swiftFiles().filter { file in
            guard file.lastPathComponent != "UsageProbe.swift", file.lastPathComponent != "ClaudeCodeBinary.swift" else { return false }
            let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
            return text.contains(/\bUsageProbe\(/) || text.contains("ClaudeCodeBinary.find")
        }
        #expect(callers.map(\.lastPathComponent) == ["UsageRefresher.swift"])

        let text = try String(contentsOf: try #require(callers.first), encoding: .utf8)
        let release = try #require(text.range(of: "#if DEBUG")?.upperBound)
        let otherwise = try #require(text.range(of: "#else", range: release..<text.endIndex))
        let end = try #require(text.range(of: "#endif", range: otherwise.upperBound..<text.endIndex))
        for call in ["UsageProbe(", "ClaudeCodeBinary.find"] {
            let found = text.ranges(of: call)
            #expect(found.count == 1, "\(call)")
            for place in found {
                #expect(place.lowerBound > otherwise.upperBound && place.upperBound < end.lowerBound, "\(call)")
            }
        }
    }
}
