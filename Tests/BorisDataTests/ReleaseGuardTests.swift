import BorisData
import Foundation
import Testing

@Suite("Настоящая сборка не знает проверочных режимов")
struct ReleaseGuardTests {
    private static var sources: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources")
    }

    private static func text(_ path: String) throws -> String {
        try String(contentsOf: sources.appendingPathComponent(path), encoding: .utf8)
    }

    @Test("Проверочная переменная останавливает запуск, а метка launchd нет")
    func checkVariables() {
        #expect(BorisPaths.checkVariable(in: ["BORIS_SNAPSHOT": "/x"]) == "BORIS_SNAPSHOT")
        #expect(BorisPaths.checkVariable(in: ["BORIS_FUTURE_MODE": "1", "HOME": "/x"]) == "BORIS_FUTURE_MODE")
        #expect(BorisPaths.checkVariable(in: ["BORIS_LAUNCHD": "1", "HOME": "/x"]) == nil)
        // An earlier version turned autostart off by starting a plain copy with this mark. If it stopped that copy, Boris would be gone with no way back.
        #expect(BorisPaths.checkVariable(in: ["BORIS_TAKE_OVER_FROM_AGENT": "1", "HOME": "/x"]) == nil)
        #expect(BorisPaths.checkVariable(in: [:]) == nil)
    }

    @Test("Запрет стоит до всего остального, что делает программа")
    func guardComesFirst() throws {
        let main = try Self.text("Boris/App/main.swift")
        let check = try #require(main.range(of: "BorisPaths.checkVariable"))
        let launch = try #require(main.range(of: "LaunchCoordinator()"))
        #expect(check.lowerBound < launch.lowerBound)
    }

    /// `strings` cannot see a name of 15 bytes or fewer, because Swift stores those inline, so the sources are what is looked at.
    @Test("Ни одна проверочная переменная не читается вне отладочной сборки")
    func namesStayInDebug() throws {
        let names = try #require(try? NSRegularExpression(pattern: "BORIS_[A-Z_]+"))
        var outside: [String] = []
        let files = try #require(FileManager.default.enumerator(at: Self.sources, includingPropertiesForKeys: nil))
        for case let file as URL in files where file.pathExtension == "swift" {
            var blocks: [Bool] = []
            for line in try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n") {
                let code = line.trimmingCharacters(in: .whitespaces)
                if code.hasPrefix("#if") {
                    blocks.append(code == "#if DEBUG" || (blocks.last ?? false))
                } else if code.hasPrefix("#else") {
                    if let last = blocks.popLast() { blocks.append(!last) }
                } else if code.hasPrefix("#endif") {
                    _ = blocks.popLast()
                } else if !code.hasPrefix("//"), !(blocks.last ?? false) {
                    let range = NSRange(code.startIndex..., in: code)
                    for match in names.matches(in: code, range: range) where !["BORIS_LAUNCHD", "BORIS_TAKE_OVER_FROM_AGENT"].contains((code as NSString).substring(with: match.range)) {
                        outside.append("\(file.lastPathComponent): \((code as NSString).substring(with: match.range))")
                    }
                }
            }
        }
        #expect(outside == [])
    }
}
