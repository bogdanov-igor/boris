import Foundation
import Testing

@Suite("Фикстуры")
struct FixtureTests {
    @Test("Эталон описывает столько запусков, сколько лежит в фикстурах")
    func runsMatchExpected() throws {
        let expected = try Fixtures.expected()
        let manifest = try Fixtures.manifest()
        #expect(manifest.runs.count == expected.runs)
        #expect(expected.status.values.reduce(0, +) == manifest.runs.count)
    }

    @Test("Для каждого запуска из манифеста есть его проект и сессия")
    func everyRunHasFiles() throws {
        let manifest = try Fixtures.manifest()
        for (id, run) in manifest.runs {
            let folder = Fixtures.root.appendingPathComponent("world/projects/\(run.project)/\(run.session)")
            #expect(FileManager.default.fileExists(atPath: folder.path), "нет папки для \(id)")
        }
    }

    @Test("В фикстурах нет личных данных")
    func noPrivateData() throws {
        let forbidden = ["/Users/", "@gmail.", "ghp_", "sk-ant"]
        let files = try #require(FileManager.default.enumerator(at: Fixtures.root, includingPropertiesForKeys: nil))
        for case let file as URL in files where ["json", "jsonl", "js"].contains(file.pathExtension) {
            let text = try String(contentsOf: file, encoding: .utf8)
            for word in forbidden {
                #expect(!text.contains(word), "\(word) в \(file.lastPathComponent)")
            }
        }
    }
}
