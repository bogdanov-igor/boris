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
        #expect(view.layer?.sublayers?.contains { $0.contents != nil } == true)
    }

    /// The pictures are drawn upright and kept, and his lean turns the layer. It has to look as if the lean were drawn.
    @Test("Наклон поворачивает готовую картинку так же, как если бы его нарисовали", arguments: [false, true])
    func leanTurnsThePicture(simple: Bool) throws {
        let view = WalrusCanvasView()
        view.frame = NSRect(x: 0, y: 0, width: 100, height: 100)
        view.look = WalrusCanvasView.Look(pose: .work, loop: 1, outfit: .none, pixels: 200, simple: simple, loops: false, pack: nil, revision: 0, upsideDown: false)
        view.leanForTest(9)
        let turned = try alpha(rendered(view))
        func drawn(_ lean: CGFloat) throws -> [UInt8] {
            var frame = WalrusFrame(name: .work, outfit: .none)
            frame.lean = lean
            return try alpha(simple ? Renderer.image(frame.simplePose(), pixels: 200, roomy: true) : Renderer.image(frame.fullPose(), pixels: 200, roomy: true))
        }
        let same = try differing(turned, drawn(9)), upright = try differing(turned, drawn(0)), otherWay = try differing(turned, drawn(-9))
        #expect(same * 6 < upright, "\(same) против \(upright)")
        #expect(same * 6 < otherWay, "\(same) против \(otherWay)")
    }

    private func rendered(_ view: NSView) throws -> CGImage {
        let layer = try #require(view.layer)
        let context = try #require(CGContext(data: nil, width: 200, height: 200, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.scaleBy(x: 200 / view.bounds.width, y: 200 / view.bounds.height)
        layer.render(in: context)
        return try #require(context.makeImage())
    }

    private func alpha(_ image: CGImage?) throws -> [UInt8] {
        let image = try #require(image)
        let context = try #require(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let data = try #require(context.data)
        return Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: image.width * image.height))
    }

    /// Points where one picture is solid and the other is not.
    private func differing(_ a: [UInt8], _ b: [UInt8]) -> Int {
        zip(a, b).filter { abs(Int($0) - Int($1)) > 128 }.count
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
