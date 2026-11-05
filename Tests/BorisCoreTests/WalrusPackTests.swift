import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import BorisCore

/// A made-up pack on disk, which each test spoils in its own way.
private struct PackFolder {
    let root: URL
    let folder: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("boris-pack-tests-\(UUID().uuidString)", isDirectory: true)
        folder = root.appendingPathComponent("My pack", isDirectory: true)
        try manifest(["name": "Вымышленный набор", "author": "Кто-то", "baseLanguage": "en", "framesPerSecond": 4])
        try picture("poses/base/1.png")
        try picture("icon/base.png", side: 36)
        try lines("en", Self.fullBook)
    }

    static let fullBook: [String: [String]] = [
        "poke": ["Hello."],
        "request": ["You are needed.", "You are needed in {project}."],
        "finish": ["Done."],
        "failure": ["It broke.", "It broke in {project}."],
        "limit": ["Limit."],
    ]

    func path(_ relative: String) -> URL { folder.appendingPathComponent(relative) }

    func manifest(_ value: [String: Any]) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: value).write(to: path("pack.json"))
    }

    func lines(_ language: String, _ book: [String: [String]]) throws {
        try FileManager.default.createDirectory(at: path("lines"), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: book).write(to: path("lines/\(language).json"))
    }

    func picture(_ relative: String, side: Int = 16) throws {
        let url = path(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let context = try #require(CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        let image = try #require(context.makeImage())
        let target = try #require(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(target, image, nil)
        #expect(CGImageDestinationFinalize(target))
    }

    func remove(_ relative: String) throws {
        try FileManager.default.removeItem(at: path(relative))
    }

    func problems() -> [WalrusPackProblem] {
        switch WalrusPackReader.read(folder) {
        case .success: return []
        case .failure(let rejection): return rejection.problems
        }
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: root)
    }
}

@Suite("walrus-packs")
struct WalrusPackTests {
    @Test("Правильный набор принимается") func valid() throws {
        let pack = try PackFolder()
        defer { pack.cleanUp() }
        let read = try WalrusPackReader.read(pack.folder).get()
        #expect(read.name == "Вымышленный набор")
        #expect(read.author == "Кто-то")
        #expect(read.baseLanguage == "en")
        #expect(read.framesPerSecond == 4)
        #expect(read.baseFrames.count == 1)
    }

    @Test("В неполном наборе сказано всё, чего не хватает, разом") func incomplete() throws {
        let pack = try PackFolder()
        defer { pack.cleanUp() }
        try pack.remove("poses/base/1.png")
        try pack.remove("icon/base.png")
        try pack.lines("en", ["poke": ["Hello."], "finish": ["Done."], "failure": ["It broke."], "request": ["Needed."]])
        #expect(Set(pack.problems()) == [.noBasePose, .noTrayIcon, .noLinesForCue(.limit)])
    }

    @Test("Пустая папка: не падает, а говорит, чего нет") func emptyFolder() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("boris-empty-pack-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        guard case .failure(let rejection) = WalrusPackReader.read(root) else {
            Issue.record("Пустая папка принята за набор")
            return
        }
        #expect(rejection.name == root.lastPathComponent)
        #expect(Set(rejection.problems) == [.noManifest, .noBasePose, .noTrayIcon])
    }

    @Test("Несуществующая папка: не падает") func missingFolder() {
        let missing = URL(fileURLWithPath: "/nonexistent/boris-pack")
        #expect(throws: WalrusPackRejection.self) { try WalrusPackReader.read(missing).get() }
    }

    @Test("Описание без имени и языка и битое описание") func manifests() throws {
        let pack = try PackFolder()
        defer { pack.cleanUp() }
        try pack.manifest(["name": "   "])
        #expect(Set(pack.problems()) == [.noName, .noBaseLanguage])
        try Data("{ не json".utf8).write(to: pack.path("pack.json"))
        #expect(pack.problems() == [.badManifest])
    }

    @Test("Нет файла реплик на базовом языке") func noBaseLines() throws {
        let pack = try PackFolder()
        defer { pack.cleanUp() }
        try pack.manifest(["name": "Набор", "baseLanguage": "ru"])
        #expect(pack.problems() == [.noLines(language: "ru")])
        try Data("не json".utf8).write(to: pack.path("lines/ru.json"))
        #expect(pack.problems() == [.badLines(language: "ru")])
    }

    @Test("Картинка, которая не читается, названа по имени") func brokenPicture() throws {
        let pack = try PackFolder()
        defer { pack.cleanUp() }
        try FileManager.default.createDirectory(at: pack.path("poses/working"), withIntermediateDirectories: true)
        try Data("это не картинка".utf8).write(to: pack.path("poses/working/1.png"))
        #expect(pack.problems() == [.badImage("poses/working/1.png")])
    }

    @Test("Обрезанный PNG тоже находится сразу") func truncatedPicture() throws {
        let pack = try PackFolder()
        defer { pack.cleanUp() }
        try pack.picture("poses/happy/1.png", side: 64)
        let whole = try Data(contentsOf: pack.path("poses/happy/1.png"))
        try whole.prefix(40).write(to: pack.path("poses/happy/1.png"))
        #expect(pack.problems() == [.badImage("poses/happy/1.png")])
    }

    @Test("Слишком большая картинка") func hugePicture() throws {
        let pack = try PackFolder()
        defer { pack.cleanUp() }
        try pack.picture("poses/happy/1.png", side: WalrusPackReader.maxSide + 1)
        #expect(pack.problems() == [.tooLarge("poses/happy/1.png")])
    }

    @Test("Ссылка наружу вместо файла не принимается") func symlink() throws {
        let pack = try PackFolder()
        defer { pack.cleanUp() }
        try pack.remove("icon/base.png")
        let outside = pack.root.appendingPathComponent("secret.png")
        try Data("секрет".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: pack.path("icon/base.png"), withDestinationURL: outside)
        #expect(pack.problems() == [.link("icon/base.png")])
    }

    @Test("Ссылка вместо целой папки поз не принимается") func folderLink() throws {
        let pack = try PackFolder()
        defer { pack.cleanUp() }
        let outside = pack.root.appendingPathComponent("elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: pack.path("poses"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: pack.path("poses/happy"), withDestinationURL: outside)
        #expect(pack.problems() == [.link("poses/happy")])
    }

    @Test("Ссылка на целую папку poses тоже не даёт выйти из набора") func topFolderLink() throws {
        let pack = try PackFolder()
        defer { pack.cleanUp() }
        let outside = pack.root.appendingPathComponent("elsewhere", isDirectory: true)
        try FileManager.default.moveItem(at: pack.path("poses"), to: outside)
        try FileManager.default.createSymbolicLink(at: pack.path("poses"), withDestinationURL: outside)
        #expect(Set(pack.problems()) == [.link("poses"), .noBasePose])
    }

    @Test("Звуки копируются, но папка под видом звука нет") func sounds() throws {
        let pack = try PackFolder()
        defer { pack.cleanUp() }
        try FileManager.default.createDirectory(at: pack.path("sounds/folder.wav"), withIntermediateDirectories: true)
        try Data("звук".utf8).write(to: pack.path("sounds/poke.wav"))
        try Data("не звук".utf8).write(to: pack.path("sounds/notes.txt"))
        let read = try WalrusPackReader.read(pack.folder).get()
        #expect(read.sounds.map(\.lastPathComponent) == ["poke.wav"])
    }

    @Test("Слишком много кадров") func tooManyFrames() throws {
        let pack = try PackFolder()
        defer { pack.cleanUp() }
        let source = try Data(contentsOf: pack.path("poses/base/1.png"))
        try FileManager.default.createDirectory(at: pack.path("poses/working"), withIntermediateDirectories: true)
        for index in 0...WalrusPackReader.maxFrames {
            try source.write(to: pack.path("poses/working/\(index).png"))
        }
        #expect(pack.problems() == [.tooManyFrames("poses/working")])
    }

    @Test("Необязательного состояния нет: вместо него базовая поза") func missingPoseFallsBack() throws {
        let pack = try PackFolder()
        defer { pack.cleanUp() }
        try pack.picture("poses/working/1.png")
        try pack.picture("poses/working/2.png")
        try pack.picture("icon/alarm.png", side: 36)
        let read = try WalrusPackReader.read(pack.folder).get()
        #expect(read.frames(for: .working).map(\.lastPathComponent) == ["1.png", "2.png"])
        #expect(read.frames(for: .sleeping) == read.baseFrames)
        #expect(read.frames(for: nil) == read.baseFrames)
        #expect(read.icon(for: .alarm).lastPathComponent == "alarm.png")
        #expect(read.icon(for: .sleeping) == read.baseIcon)
    }

    @Test("Кадры идут по номерам, а не по алфавиту") func frameOrder() throws {
        let pack = try PackFolder()
        defer { pack.cleanUp() }
        for index in [10, 2, 1] { try pack.picture("poses/working/\(index).png") }
        let read = try WalrusPackReader.read(pack.folder).get()
        #expect(read.frames(for: .working).map(\.lastPathComponent) == ["1.png", "2.png", "10.png"])
    }

    @Test("Нет перевода: реплики на базовом языке") func baseLanguage() throws {
        let pack = try PackFolder()
        defer { pack.cleanUp() }
        let read = try WalrusPackReader.read(pack.folder).get()
        #expect(read.lines(for: .poke, project: nil, language: "ru") == ["Hello."])
    }

    @Test("Перевод неполный: чего нет, на базовом языке, остальное на выбранном") func partialTranslation() throws {
        let pack = try PackFolder()
        defer { pack.cleanUp() }
        try pack.lines("ru", ["poke": ["Привет."]])
        let read = try WalrusPackReader.read(pack.folder).get()
        #expect(read.lines(for: .poke, project: nil, language: "ru") == ["Привет."])
        #expect(read.lines(for: .limit, project: nil, language: "ru") == ["Limit."])
        #expect(read.lines(for: .poke, project: nil, language: "en") == ["Hello."])
    }

    @Test("Сбой с проектом говорит про проект, без проекта не показывает метку") func projectMark() throws {
        let pack = try PackFolder()
        defer { pack.cleanUp() }
        let read = try WalrusPackReader.read(pack.folder).get()
        #expect(read.lines(for: .failure, project: "shop-api", language: "en") == ["It broke in shop-api."])
        #expect(read.lines(for: .failure, project: nil, language: "en") == ["It broke."])
        #expect(read.lines(for: .request, project: "shop-api", language: "en") == ["You are needed.", "You are needed in shop-api."])
    }

    @Test("Имя проекта не разбирается как формат") func projectIsNotAFormat() throws {
        let pack = try PackFolder()
        defer { pack.cleanUp() }
        let read = try WalrusPackReader.read(pack.folder).get()
        #expect(read.lines(for: .failure, project: "%@%@%n", language: "en") == ["It broke in %@%@%n."])
    }

    @Test("У события должна быть реплика и без проекта") func needsPlainLine() throws {
        let pack = try PackFolder()
        defer { pack.cleanUp() }
        var book = PackFolder.fullBook
        book["failure"] = ["It broke in {project}."]
        try pack.lines("en", book)
        #expect(pack.problems() == [.noPlainLine(.failure)])
    }

    @Test("Слишком длинная реплика") func longLine() throws {
        let pack = try PackFolder()
        defer { pack.cleanUp() }
        var book = PackFolder.fullBook
        book["poke"] = [String(repeating: "а", count: WalrusPackReader.maxLineLength + 1)]
        try pack.lines("en", book)
        #expect(pack.problems() == [.lineTooLong(.poke)])
    }

    @Test("Импорт копирует только файлы формата и не трогает исходник") func shelfCopiesKnownFiles() throws {
        let pack = try PackFolder()
        defer { pack.cleanUp() }
        try Data("#!/bin/sh\n".utf8).write(to: pack.path("install.sh"))
        try FileManager.default.createDirectory(at: pack.path("poses/working"), withIntermediateDirectories: true)
        try Data("не картинка, но и не png".utf8).write(to: pack.path("poses/working/notes.txt"))
        let shelf = WalrusPackShelf(folder: pack.root.appendingPathComponent("shelf", isDirectory: true))
        let placed = try shelf.add(from: pack.folder).get()

        #expect(shelf.list().map(\.id) == [placed.id])
        #expect(FileManager.default.fileExists(atPath: placed.folder.appendingPathComponent("pack.json").path))
        #expect(FileManager.default.fileExists(atPath: placed.folder.appendingPathComponent("poses/base/1.png").path))
        #expect(FileManager.default.fileExists(atPath: placed.folder.appendingPathComponent("lines/en.json").path))
        #expect(!FileManager.default.fileExists(atPath: placed.folder.appendingPathComponent("install.sh").path))
        #expect(!FileManager.default.fileExists(atPath: placed.folder.appendingPathComponent("poses/working").path))
        #expect(FileManager.default.fileExists(atPath: pack.path("install.sh").path))
    }

    @Test("Импорт неполного набора ничего не добавляет на полку") func shelfRefusesIncomplete() throws {
        let pack = try PackFolder()
        defer { pack.cleanUp() }
        try pack.remove("icon/base.png")
        let shelf = WalrusPackShelf(folder: pack.root.appendingPathComponent("shelf", isDirectory: true))
        #expect(throws: WalrusPackRejection(name: "Вымышленный набор", problems: [.noTrayIcon])) { try shelf.add(from: pack.folder).get() }
        #expect(shelf.list().isEmpty)
    }

    @Test("Набор с тем же именем заменяется") func shelfReplacesSameName() throws {
        let pack = try PackFolder()
        defer { pack.cleanUp() }
        let shelf = WalrusPackShelf(folder: pack.root.appendingPathComponent("shelf", isDirectory: true))
        let first = try shelf.add(from: pack.folder).get()
        try pack.picture("poses/happy/1.png")
        let second = try shelf.add(from: pack.folder).get()
        #expect(first.id != second.id)
        #expect(shelf.list().map(\.id) == [second.id])
        #expect(shelf.pack(id: first.id) == nil)
        #expect(shelf.pack(id: second.id)?.poses[.happy]?.count == 1)
    }

    @Test("Удалённый или испорченный набор: встроенный морж, без падения") func shelfSurvivesDamage() throws {
        let pack = try PackFolder()
        defer { pack.cleanUp() }
        let shelf = WalrusPackShelf(folder: pack.root.appendingPathComponent("shelf", isDirectory: true))
        let placed = try shelf.add(from: pack.folder).get()
        try FileManager.default.removeItem(at: placed.folder.appendingPathComponent("poses/base/1.png"))
        #expect(shelf.pack(id: placed.id) == nil)
        #expect(shelf.list().isEmpty)
        #expect(shelf.pack(id: nil) == nil)
        #expect(shelf.pack(id: "../../etc") == nil)
        shelf.remove(id: placed.id)
        #expect(!FileManager.default.fileExists(atPath: placed.folder.path))
    }
}

@Suite("wardrobe")
struct WardrobeMemoryTests {
    @Test("Выбор наряда и набора переживает перезапуск", arguments: [WardrobeMode.byDate, .off, .manual(.santa), .manual(.fish)])
    func roundTrip(mode: WardrobeMode) throws {
        let settings = WardrobeSettings(mode: mode, userBirthday: MonthDay(month: 3, day: 14), pack: "abc")
        let again = try JSONDecoder().decode(WardrobeSettings.self, from: JSONEncoder().encode(settings))
        #expect(again == settings)
    }

    @Test("Настройки старой версии, где наборов ещё не было, читаются") func olderSettings() throws {
        let old = #"{"mode":{"manual":{"_0":"santa"}}}"#
        let settings = try JSONDecoder().decode(WardrobeSettings.self, from: Data(old.utf8))
        #expect(settings.mode == .manual(.santa))
        #expect(settings.pack == nil)
    }
}
