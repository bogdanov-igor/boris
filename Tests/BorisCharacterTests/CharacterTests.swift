import CoreGraphics
import Foundation
import BorisCore
import Testing
@testable import BorisCharacter

@Suite("Разбор SVG-путей")
struct SVGPathTests {
    @Test("Абсолютные и относительные команды") func commands() {
        let box = SVGPath.path("M10 20h30l-30 30h30").boundingBox
        #expect(box == CGRect(x: 10, y: 20, width: 30, height: 30))
        #expect(SVGPath.path("M0 0H5V7Z").boundingBox == CGRect(x: 0, y: 0, width: 5, height: 7))
    }

    @Test("Числа без пробела и с минусом") func compactNumbers() {
        #expect(SVGPath.path("M-24 4L25 0L-18 11").boundingBox == CGRect(x: -24, y: 0, width: 49, height: 11))
        #expect(SVGPath.path("M.5 .25L1e1 -2.5e-1").boundingBox.maxX == 10)
    }

    @Test("Дуга приходит в конечную точку") func arc() {
        let box = SVGPath.path("M0 10A10 10 0 0 1 10 0").boundingBox
        #expect(abs(box.minX) < 0.01)
        #expect(abs(box.maxX - 10) < 0.01)
    }
}

@Suite("character")
struct CharacterTests {
    private let moods: [Mood] = [.alarm, .broken, .waiting, .tired, .alert, .happy, .hmm, .working(agents: 1), .sleeping]

    private func alpha(_ image: CGImage?) -> [UInt8] {
        guard let image, let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else { return [] }
        return (0..<image.height).flatMap { y in
            (0..<image.width).map { x in bytes[y * image.bytesPerRow + x * 4 + 3] }
        }
    }

    private func icon(_ mood: Mood, scale: Int) -> [UInt8] {
        let name = PoseName(mood: mood)
        return alpha(Renderer.template(Timeline.simple(name, t: name.keyTime, mono: true), scale: scale))
    }

    @Test("Каждому настроению своя поза") func mapping() {
        #expect(Set(moods.map { PoseName(mood: $0) }).count == moods.count)
        #expect(PoseName(mood: .hmm) == .stopped)
        #expect(PoseName(mood: .tired) == .limit)
    }

    /// The closest pair today differs by 43 pixels at 1x and 270 at 2x.
    @Test("Настроения различимы в значке", arguments: [2, 1])
    func moodsDiffer(scale: Int) {
        let icons = moods.map { icon($0, scale: scale) }
        for a in icons.indices {
            for b in icons.indices where b > a {
                let changed = zip(icons[a], icons[b]).filter { abs(Int($0) - Int($1)) > 64 }.count
                #expect(changed >= (scale == 2 ? 150 : 30), "\(moods[a]) и \(moods[b]) отличаются всего на \(changed) точек")
            }
        }
    }

    @Test("Значок нужного размера, с прозрачным фоном") func iconShape() {
        let image = Renderer.template(Timeline.simple(.sleep, t: 0.5, mono: true), scale: 2)
        #expect(image?.width == 42)
        #expect(image?.height == 36)
        let pixels = alpha(image)
        #expect(pixels.first == 0)
        #expect(pixels.contains { $0 > 200 })
    }

    @Test("У всех поз прозрачные углы", arguments: PoseName.allCases)
    func transparentCorners(name: PoseName) {
        for image in [Renderer.image(Timeline.full(name, t: name.keyTime), pixels: 128), Renderer.image(Timeline.simple(name, t: name.keyTime, mono: false), pixels: 128)] {
            let pixels = alpha(image)
            #expect(pixels.count == 128 * 128)
            #expect(pixels[0] == 0 && pixels[127] == 0 && pixels[pixels.count - 1] == 0)
            #expect(pixels.contains { $0 == 255 })
        }
    }

    @Test("Дым в значке только при работе") func smokeOnlyWhenWorking() {
        for name in PoseName.allCases {
            for step in 0..<Timeline.framesPerLoop {
                let pose = Timeline.simple(name, t: CGFloat(step) / CGFloat(Timeline.framesPerLoop), mono: true)
                #expect((pose.smoke != nil) == (name == .work))
            }
        }
    }

    @Test("Спящая, усталая и сломанная сигара не горит") func unlitCigars() {
        for name in [PoseName.sleep, .limit, .broken] {
            let pose = Timeline.full(name, t: 0.3)
            #expect(pose.cigar == .droop)
            #expect(pose.lit == false)
            #expect(pose.smoke == nil)
        }
    }

    @Test("Поза зависит только от времени") func pureFunction() {
        for name in PoseName.allCases {
            #expect(Timeline.full(name, t: 0.37) == Timeline.full(name, t: 0.37))
            #expect(Timeline.simple(name, t: 0.37, mono: false) == Timeline.simple(name, t: 0.37, mono: false))
        }
    }

    @Test("Тревога: сигара падает один раз, монокль вылетел") func alarmOnce() {
        let falling = Timeline.full(.alarm, t: 0.2)
        let later = Timeline.full(.alarm, t: 0.2, firstLoop: false)
        #expect(falling.droppedCigar != later.droppedCigar)
        #expect(later.droppedCigar == Hat(178, 234, 6))
        #expect(later.monocle == .popped)
        #expect(later.cigar == nil)
        #expect(later.jaw == 1)
    }

    @Test("Скорость растёт с числом агентов, с пределом") func workSpeed() {
        let one = Timeline.loop(for: .working(agents: 1))
        let four = Timeline.loop(for: .working(agents: 4))
        let forty = Timeline.loop(for: .working(agents: 40))
        #expect(one > four)
        #expect(four > forty)
        #expect(forty >= Timeline.fastestWorkLoop)
        #expect(Timeline.loop(for: .working(agents: 100_000)) == Timeline.fastestWorkLoop)
        #expect(Timeline.loop(for: .working(agents: 0)) == one)
    }

    @Test("Спящий значок неподвижен") func stillStates() {
        #expect(!PoseName.sleep.movesInMenuBar)
        #expect(PoseName.work.movesInMenuBar)
        #expect(PoseName.alarm.movesInMenuBar)
    }

    @Test("Моргание короткое и редкое") func blink() {
        let samples = stride(from: 0.0, to: 53.0, by: 0.01).filter { Timeline.isBlinking(elapsed: $0) }
        #expect(samples.count > 100 && samples.count < 300)
    }
}

@Suite("wardrobe: рисунки")
struct OutfitTests {
    private func pixels(_ image: CGImage?) -> [UInt8] {
        guard let image, let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else { return [] }
        return (0..<image.height).flatMap { y in (0..<image.width * 4).map { x in bytes[y * image.bytesPerRow + x] } }
    }

    @Test("Каждый наряд виден и в значке, и на витрине") func outfitsShow() {
        for outfit in Outfit.allCases where outfit != .none {
            let dressed = pixels(Renderer.image(Dress.shelf(outfit), pixels: 128, roomy: true))
            let plain = pixels(Renderer.image(Dress.shelf(.none), pixels: 128, roomy: true))
            let changed = zip(dressed, plain).filter { abs(Int($0) - Int($1)) > 48 }.count
            #expect(changed > 200, "\(outfit) почти не меняет рисунок: \(changed)")
        }
        // In one colour the crow looks like the base icon on purpose, and the fish has no icon.
        for outfit in Outfit.allCases where ![.none, .crow, .fish].contains(outfit) {
            let dressed = pixels(Renderer.template(Dress.shelfSimple(outfit, mono: true), scale: 2))
            let plain = pixels(Renderer.template(Dress.shelfSimple(.none, mono: true), scale: 2))
            #expect(dressed != plain, "\(outfit) не виден в значке")
        }
    }

    @Test("Шляпа следует за позой и не закрывает глаза", arguments: PoseName.allCases)
    func outfitKeepsMood(name: PoseName) {
        let base = Timeline.full(name, t: name.keyTime)
        let dressed = Dress.apply(.santa, to: base)
        #expect(dressed.eyeLeft == base.eyeLeft)
        #expect(dressed.eyeRight == base.eyeRight)
        #expect(dressed.headwear == .santa)
        #expect(dressed.hat.y == base.hat.y + 4)
    }

    @Test("Ночной колпак не усыпляет") func nightcapKeepsEyes() {
        let dressed = Dress.apply(.nightcap, to: Timeline.full(.work, t: 0.25))
        #expect(dressed.eyeLeft == .open)
    }

    @Test("Сердечки только в спокойных глазах") func hearts() {
        #expect(Dress.apply(.hearts, to: Timeline.full(.work, t: 0.25)).eyeLeft == .heart)
        #expect(Dress.apply(.hearts, to: Timeline.full(.alarm, t: 0.7)).eyeLeft == .wide)
    }

    @Test("Очки вместо монокля, при тревоге монокль уже вылетел") func glasses() {
        #expect(Dress.apply(.pixel, to: Timeline.full(.work, t: 0.25)).monocle == .pixel)
        #expect(Dress.apply(.pixel, to: Timeline.full(.alarm, t: 0.7)).monocle == .popped)
    }

    @Test("Рыбы нет в значке") func noFishInMenuBar() {
        #expect(Dress.apply(.fish, to: Timeline.simple(.work, t: 0.25, mono: true), mono: true).cigar == .flat)
        #expect(Dress.apply(.fish, to: Timeline.simple(.work, t: 0.25, mono: false), mono: false).cigar == .fish)
    }

    @Test("Все реакции рисуются", arguments: Act.allCases)
    func actsDraw(act: Act) {
        let picture = pixels(Renderer.image(Timeline.act(act, t: act.stillTime), pixels: 96, roomy: true))
        #expect(picture.contains(255))
        #expect(picture[3] == 0)
    }

    @Test("Вверх ногами это другая картинка") func upsideDown() {
        var pose = Timeline.full(.work, t: 0.25)
        let normal = pixels(Renderer.image(pose, pixels: 96, roomy: true))
        pose.upsideDown = true
        #expect(pixels(Renderer.image(pose, pixels: 96, roomy: true)) != normal)
    }
}

/// He once lost his Santa hat when he turned round. Whatever he wears stays on, from any side and in any frame.
@Suite("Наряд со всех сторон")
struct OutfitAllSidesTests {
    private let hats: [Outfit] = [.santa, .witch, .party, .scholar, .nightcap, .flower]

    private func pixels(_ image: CGImage?) -> [UInt8] {
        guard let image, let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else { return [] }
        return Array(UnsafeBufferPointer(start: bytes, count: image.bytesPerRow * image.height))
    }

    /// The rows above the top of his head, where only the hat is. The head starts at 26 in a drawing that starts at -56.
    private func aboveHead(_ image: CGImage?) -> [UInt8] {
        guard let image else { return [] }
        let rows = image.height * 70 / 306
        return Array(pixels(image).prefix(rows * image.bytesPerRow))
    }

    private func picture(_ outfit: Outfit, back: Bool) -> CGImage? {
        var pose = Pose()
        pose.back = back
        return Renderer.image(Dress.apply(outfit, to: pose), pixels: 200)
    }

    @Test("Сзади та же шляпа, что и спереди", arguments: [Outfit.none, .santa, .witch, .party, .scholar, .nightcap, .flower])
    func sameHat(outfit: Outfit) {
        let front = aboveHead(picture(outfit, back: false))
        #expect(!front.isEmpty)
        #expect(front == aboveHead(picture(outfit, back: true)))
    }

    @Test("Шляпы различимы и со спины")
    func hatsDifferFromBehind() {
        let looks = ([Outfit.none] + hats).map { aboveHead(picture($0, back: true)) }
        #expect(Set(looks).count == looks.count)
    }

    private var everyFrame: [(name: String, pose: Pose)] {
        let frames = (0..<8).map { CGFloat($0) / 8 }
        let moods = PoseName.allCases.flatMap { name in frames.map { ("\(name) \($0)", Timeline.full(name, t: $0)) } }
        let acts = Act.allCases.flatMap { act in frames.map { ("\(act) \($0)", Timeline.act(act, t: $0)) } }
        return moods + acts
    }

    @Test("Наряд виден в каждой позе и реакции, в каждом кадре", arguments: [Outfit.santa, .witch, .party, .scholar, .nightcap, .flower, .crow])
    func staysOn(outfit: Outfit) {
        for (name, pose) in everyFrame {
            let plain = pixels(Renderer.image(pose, pixels: 48))
            let dressed = pixels(Renderer.image(Dress.apply(outfit, to: pose), pixels: 48))
            #expect(plain != dressed, "\(outfit) пропал: \(name)")
        }
    }

    @Test("Среди реакций есть кадры со спины, и шляпа в них та же", arguments: [Outfit.none, .santa, .witch, .party, .scholar, .nightcap, .flower])
    func sameHatInEveryBackFrame(outfit: Outfit) {
        let backFrames = everyFrame.filter(\.pose.back)
        #expect(!backFrames.isEmpty)
        for (name, pose) in backFrames {
            // Smoke rises past the hat, and it is not what this is about.
            var behind = Dress.apply(outfit, to: pose)
            behind.smoke = nil
            var front = behind
            front.back = false
            #expect(aboveHead(Renderer.image(behind, pixels: 200)) == aboveHead(Renderer.image(front, pixels: 200)), "\(outfit): \(name)")
        }
    }

    @Test("Рыба во рту видна со спины, а сигары тогда нет")
    func fishFromBehind() {
        let cigar = pixels(picture(.none, back: true))
        let fish = pixels(picture(.fish, back: true))
        #expect(cigar != fish)
    }

    @Test("Со спины нет того, чего нет во рту")
    func emptyMouthFromBehind() {
        var pose = Pose()
        pose.back = true
        let withCigar = pixels(Renderer.image(pose, pixels: 200))
        pose.cigar = nil
        #expect(withCigar != pixels(Renderer.image(pose, pixels: 200)))
    }

    @Test("Погасшая сигара не загорается, когда он отвернулся")
    func unlitFromBehind() {
        var pose = Pose()
        pose.back = true
        let lit = pixels(Renderer.image(pose, pixels: 200))
        pose.lit = false
        #expect(lit != pixels(Renderer.image(pose, pixels: 200)))
    }
}
