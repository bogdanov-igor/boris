import AppKit
import BorisCharacter
@testable import BorisCore
import Foundation
import Testing
@testable import Boris

/// The real view with its real timer, so "a still walrus costs nothing" is not only a promise of a pure function.
/// No window is ever opened: `pretendVisible` stands in for being seen, and the tests run one at a time because the counter is shared.
@MainActor
@Suite("walrus-canvas", .serialized)
struct WalrusCanvasTests {
    private func look(_ pose: PoseName, loops: Bool = false, pack: WalrusPack? = nil) -> WalrusCanvasView.Look {
        WalrusCanvasView.Look(pose: pose, loop: 1, outfit: .none, pixels: 32, simple: true, loops: loops, pack: pack, revision: 0, upsideDown: false)
    }

    /// How many times his timer fired in a third of a second.
    private func fires(_ view: WalrusCanvasView, visible: Bool = true) -> Int {
        WalrusCanvasView.pretendVisible = visible
        defer { WalrusCanvasView.pretendVisible = false }
        let start = WalrusCanvasView.ticks
        view.refreshForTest()
        RunLoop.main.run(until: Date().addingTimeInterval(0.35))
        return WalrusCanvasView.ticks - start
    }

    /// Every state that can last for hours.
    @Test("В покое таймер не срабатывает ни разу", arguments: [PoseName.sleep, .wait, .limit, .broken, .watch])
    func stillCostsNothing(pose: PoseName) {
        let view = WalrusCanvasView()
        view.look = look(pose)
        #expect(fires(view) == 0)
    }

    /// With Reduce Motion on, nothing may move, so on such a Mac there is nothing to see here.
    private var canMove: Bool { !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    @Test("Работающий морж движется, пока его видно") func workMoves() {
        guard canMove else { return }
        let view = WalrusCanvasView()
        view.look = look(.work)
        #expect(fires(view) > 0)
    }

    @Test("Того, что не видно, таймер не касается", arguments: [PoseName.work, .alarm, .happy])
    func hiddenCostsNothing(pose: PoseName) {
        let view = WalrusCanvasView()
        view.look = look(pose)
        #expect(fires(view, visible: false) == 0)
    }

    @Test("Предпросмотр движется и в позе, которая обычно стоит") func previewLoops() {
        guard canMove else { return }
        let view = WalrusCanvasView()
        view.look = look(.sleep, loops: true)
        #expect(fires(view) > 0)
    }

    @Test("Единственный кадр набора не тратит таймер") func packWithOneFrame() {
        let view = WalrusCanvasView()
        view.look = look(.work, pack: pack(frames: [URL(fileURLWithPath: "/nonexistent/1.png")]))
        #expect(fires(view) == 0)
    }

    @Test("Файл набора пропал: вместо пустого места встроенный морж") func missingPackFile() {
        let view = WalrusCanvasView()
        view.look = look(.sleep, pack: pack(frames: [URL(fileURLWithPath: "/nonexistent/1.png")]))
        #expect(view.layer?.contents != nil)
    }

    /// The format promises that importing a pack again brings its new version. The old folder goes, so the walrus has to move too.
    @Test("Новая версия выбранного набора: морж переходит на неё и не остаётся без файлов") func reimportActivePack() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("boris-app-tests-\(UUID().uuidString)", isDirectory: true)
        let store = StateStore(folder: folder)
        let model = AppModel(settings: AppSettings(defaults: nil), store: store, live: false)
        let source = WalrusDev.writePackFolder(name: "Вымышленный набор")
        defer {
            WalrusArt.shared.pack = nil
            store.flush()
            try? FileManager.default.removeItem(at: folder)
            try? FileManager.default.removeItem(at: source)
        }
        let first = try #require(WalrusDev.makePack(in: model.packShelf, name: "Вымышленный набор"))
        model.usePack(first)

        model.importPack(from: source)
        while model.walrusPage.importing { try await Task.sleep(for: .milliseconds(20)) }

        let active = try #require(WalrusArt.shared.pack)
        #expect(active.id != first.id)
        #expect(FileManager.default.fileExists(atPath: active.baseFrames[0].path))
        #expect(model.settings.wardrobe.pack == active.id)
    }

    private func pack(frames: [URL]) -> WalrusPack {
        WalrusPack(
            id: "x", folder: URL(fileURLWithPath: "/nonexistent"), name: "x", author: nil, baseLanguage: "en", framesPerSecond: 8,
            baseFrames: frames, poses: [:], baseIcon: URL(fileURLWithPath: "/nonexistent/i.png"), icons: [:], lines: [:], sounds: []
        )
    }
}
