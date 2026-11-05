import CoreGraphics
import Foundation
import BorisCore
import Testing
@testable import BorisCharacter

@Suite("walrus-frame")
struct WalrusFrameTests {
    private func pixels(_ image: CGImage?) -> [UInt8] {
        guard let image, let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else { return [] }
        return Array(UnsafeBufferPointer(start: bytes, count: image.height * image.bytesPerRow))
    }

    private func simple(_ frame: WalrusFrame) -> [UInt8] { pixels(Renderer.image(frame.simplePose(), pixels: 80, roomy: true)) }
    private func full(_ frame: WalrusFrame) -> [UInt8] { pixels(Renderer.image(frame.fullPose(), pixels: 80, roomy: true)) }

    private func acted(_ act: Act, outfit: Outfit = .none, step: Int = 8) -> WalrusFrame {
        var frame = WalrusFrame(name: .watch, outfit: outfit)
        frame.act = act
        frame.actStep = step
        return frame
    }

    @Test("Ключевой кадр совпадает с тем, что было раньше", arguments: PoseName.allCases)
    func keyFrame(name: PoseName) {
        #expect(WalrusFrame(name: name, outfit: .none).fullPose() == Timeline.full(name, t: name.keyTime, firstLoop: false))
        #expect(WalrusFrame(name: name, outfit: .none).simplePose() == Timeline.simple(name, t: name.keyTime, mono: false))
    }

    @Test("Цикл идёт по шагам", arguments: PoseName.allCases)
    func loop(name: PoseName) {
        var frame = WalrusFrame(name: name, outfit: .none)
        frame.step = 6
        #expect(frame.fullPose() == Timeline.full(name, t: 0.25, firstLoop: false))
    }

    @Test("Сигара падает только в первом цикле") func firstLoop() {
        var frame = WalrusFrame(name: .alarm, outfit: .none)
        frame.step = 4
        let later = frame.fullPose()
        frame.firstLoop = true
        #expect(frame.fullPose().droppedCigar != later.droppedCigar)
    }

    @Test("Реакция заменяет позу, мягкий тык только сжимает её") func actsAndSoftPoke() {
        #expect(acted(.annoyed).fullPose().eyeLeft == .lid)
        var soft = WalrusFrame(name: .alarm, outfit: .none)
        soft.act = .poke
        soft.softPoke = true
        let pose = soft.fullPose()
        #expect(pose.eyeLeft == .wide)
        #expect(pose.squash != CGSize(width: 1, height: 1))
    }

    @Test("Моргание закрывает глаза, реакция важнее") func blink() {
        var frame = WalrusFrame(name: .watch, outfit: .none)
        frame.blink = true
        #expect(frame.fullPose().eyeLeft == .closed)
        #expect(frame.simplePose().eyeLeft == .closed)
        frame.act = .annoyed
        #expect(frame.fullPose().eyeLeft == .lid)
    }

    @Test("Зрачки следят за курсором и не выходят за пределы") func gaze() {
        let right = WalrusFrame.Gaze(toward: 400, 0)
        #expect(right == WalrusFrame.Gaze(x: 3, y: 0))
        let upLeft = WalrusFrame.Gaze(toward: -300, -300)
        #expect(upLeft.x < 0 && upLeft.y < 0)
        #expect(WalrusFrame.Gaze(toward: 1, 1) == WalrusFrame.Gaze(x: 0, y: 0))
        for name in PoseName.allCases where name.followsPointer {
            var frame = WalrusFrame(name: name, outfit: .none)
            frame.gaze = right
            #expect(frame.fullPose().look.x == 6)
            #expect(abs(frame.simplePose().look.x) < 2.5)
        }
    }

    @Test("Спящий и сломанный за курсором не следят", arguments: [PoseName.sleep, .broken, .happy, .limit])
    func noGaze(name: PoseName) {
        var frame = WalrusFrame(name: name, outfit: .none)
        let before = frame.fullPose()
        frame.gaze = WalrusFrame.Gaze(x: 3, y: 3)
        #expect(frame.fullPose() == before)
    }

    @Test("Разные кадры различимы, одинаковые дают один ключ") func keys() {
        var a = WalrusFrame(name: .work, outfit: .santa)
        a.step = 3
        var b = a
        #expect(a == b)
        #expect(Set([a, b]).count == 1)
        b.step = 4
        #expect(a != b)
    }

    @Test("У каждой реакции своя картинка в упрощённом рисунке", arguments: Act.allCases)
    func simpleActs(act: Act) {
        let frame = acted(act, step: Int(act.stillTime * Double(WalrusFrame.actSteps)))
        #expect(simple(frame) != simple(WalrusFrame(name: .watch, outfit: .none)), "\(act) выглядит как обычная поза")
        #expect(full(frame) != full(WalrusFrame(name: .watch, outfit: .none)))
    }

    /// Hearts and pixel glasses are the two that only show on open eyes and a worn monocle, so they have a test of their own.
    @Test("Наряд виден в каждой позе и реакции и в обоих рисунках", arguments: [Outfit.santa, .witch, .party, .scholar, .nightcap, .flower, .crow])
    func outfitEverywhere(outfit: Outfit) {
        for name in PoseName.allCases {
            #expect(simple(WalrusFrame(name: name, outfit: outfit)) != simple(WalrusFrame(name: name, outfit: .none)), "\(outfit) пропал в упрощённом: \(name)")
            #expect(full(WalrusFrame(name: name, outfit: outfit)) != full(WalrusFrame(name: name, outfit: .none)), "\(outfit) пропал в полном: \(name)")
        }
        for act in Act.allCases where act != .back || outfit.isHeadwear {
            let step = Int(act.stillTime * Double(WalrusFrame.actSteps))
            #expect(simple(acted(act, outfit: outfit, step: step)) != simple(acted(act, step: step)), "\(outfit) пропал в упрощённой реакции: \(act)")
            #expect(full(acted(act, outfit: outfit, step: step)) != full(acted(act, step: step)), "\(outfit) пропал в реакции: \(act)")
        }
    }

    @Test("Сердечки и пиксельные очки видны, когда глаза открыты", arguments: [Outfit.pixel, .hearts], [PoseName.watch, .work, .wait, .alert])
    func eyeOutfits(outfit: Outfit, name: PoseName) {
        #expect(simple(WalrusFrame(name: name, outfit: outfit)) != simple(WalrusFrame(name: name, outfit: .none)))
        #expect(full(WalrusFrame(name: name, outfit: outfit)) != full(WalrusFrame(name: name, outfit: .none)))
    }

    @Test("Рыба занимает место сигары и в реакциях, где сигара есть") func fish() {
        #expect(WalrusFrame(name: .work, outfit: .fish).fullPose().cigar == .fish)
        #expect(WalrusFrame(name: .work, outfit: .fish).simplePose().cigar == .fish)
        #expect(acted(.annoyed, outfit: .fish).fullPose().cigar == .fish)
        #expect(acted(.annoyed, outfit: .fish).simplePose().cigar == .fish)
    }

    @Test("Несколько агентов: та же поза, что у одного, но быстрее") func samePose() {
        #expect(PoseName(mood: .working(agents: 1)) == PoseName(mood: .working(agents: 9)))
        #expect(Timeline.loop(for: .working(agents: 9)) < Timeline.loop(for: .working(agents: 1)))
    }

    @Test("Каждая поза набора стоит за своим настроением") func packPoses() {
        let moods: [(Mood, WalrusPose)] = [(.working(agents: 2), .working), (.waiting, .waiting), (.happy, .happy), (.hmm, .hmm), (.alert, .alert), (.tired, .tired), (.alarm, .alarm), (.broken, .broken), (.sleeping, .sleeping)]
        for (mood, pose) in moods {
            #expect(PoseName(mood: mood).packPose == pose)
            #expect(WalrusPose(mood: mood) == pose)
        }
        #expect(PoseName.watch.packPose == nil)
    }
}

private extension Outfit {
    var isHeadwear: Bool {
        switch self {
        case .santa, .witch, .party, .scholar, .nightcap, .flower: return true
        default: return false
        }
    }
}
