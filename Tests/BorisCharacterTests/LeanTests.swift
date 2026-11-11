import CoreGraphics
import Foundation
import BorisCore
import Testing
@testable import BorisCharacter

@Suite("walrus-lean")
struct LeanTests {
    /// Plays him at the timer's pace and keeps every move he made and every degree he showed.
    private func play(seed: UInt64, seconds: TimeInterval) -> (moves: [Lean.Move], degrees: [CGFloat]) {
        var lean = Lean(seed: seed)
        var moves = [lean.move]
        var degrees: [CGFloat] = []
        for t in stride(from: 0, through: seconds, by: WalrusMotion.frameInterval) {
            degrees.append(lean.degrees(at: t, moving: true))
            if lean.move != moves.last { moves.append(lean.move) }
        }
        return (moves, degrees)
    }

    @Test("Наклон не больше 10 градусов в любую сторону", arguments: 0..<8 as Range<UInt64>)
    func withinTen(seed: UInt64) {
        let degrees = play(seed: seed, seconds: 900).degrees
        #expect(degrees.allSatisfy { abs($0) <= Lean.most })
        // Half degrees, so a picture can be found again.
        #expect(degrees.allSatisfy { ($0 * 2).rounded() == $0 * 2 })
        #expect(degrees.contains { $0 > 0 } && degrees.contains { $0 < 0 })
    }

    @Test("Сначала стоит прямо") func startsUpright() {
        var lean = Lean(seed: 3)
        for t in stride(from: 0, to: Lean.hold.lowerBound, by: 0.1) {
            #expect(lean.degrees(at: t, moving: true) == 0)
        }
    }

    @Test("Поворот доходит до цели, и наклон держится, пока не придёт время следующего", arguments: 1..<4 as Range<UInt64>)
    func reachesAndHolds(seed: UInt64) {
        // The last move may not have finished.
        let moves = play(seed: seed, seconds: 600).moves.dropLast()
        #expect(moves.count > 40)
        var lean = Lean(seed: seed)
        for move in moves {
            let halfway = lean.degrees(at: move.start + move.turn / 2, moving: true)
            #expect(halfway >= min(move.from, move.to) && halfway <= max(move.from, move.to))
            #expect(lean.degrees(at: move.start + move.turn, moving: true) == move.to)
            #expect(lean.degrees(at: move.end - 0.01, moving: true) == move.to)
            #expect(lean.move == move)
            #expect(move.hold >= Lean.hold.lowerBound && move.hold <= Lean.hold.upperBound)
        }
    }

    @Test("Каждый поворот идёт туда, где он ещё не стоит, с того места, где он стоял") func turnsSomewhere() {
        let moves = play(seed: 11, seconds: 600).moves
        for (before, move) in zip(moves, moves.dropFirst()) {
            #expect(move.from == before.to)
            #expect(move.start == before.end)
            #expect(abs(move.to - move.from) >= CGFloat(Lean.least))
        }
    }

    @Test("Бывают и быстрые, и медленные повороты") func quickAndSlow() {
        let turns = play(seed: 21, seconds: 900).moves.dropFirst().map(\.turn)
        #expect(turns.allSatisfy { Lean.quick.contains($0) || Lean.slow.contains($0) })
        #expect(turns.contains { Lean.quick.contains($0) })
        #expect(turns.contains { Lean.slow.contains($0) })
    }

    @Test("Прямо он стоит достаточно часто, но не всё время") func uprightOften() {
        let moves = play(seed: 5, seconds: 3000).moves
        let upright = Double(moves.filter { $0.to == 0 }.count) / Double(moves.count)
        #expect(upright > 0.2 && upright < 0.5)
        #expect(moves.contains { $0.to == Lean.most || $0.to == -Lean.most })
    }

    @Test("Одно зерно, один и тот же морж") func seeded() {
        #expect(play(seed: 42, seconds: 120).degrees == play(seed: 42, seconds: 120).degrees)
        #expect(play(seed: 42, seconds: 120).degrees != play(seed: 43, seconds: 120).degrees)
    }

    /// The same rule decides as for the timer: with Reduce Motion, still or out of sight, he stands upright and his lean waits.
    @Test("С уменьшением движения, в покое и невидимым наклон не меняется", arguments: [
        (true, true, true),  // Reduce Motion
        (false, true, false),  // a still state
        (true, false, false),  // nobody can see him
    ])
    func noLeanWhenStill(moves: Bool, visible: Bool, reduceMotion: Bool) {
        let moving = WalrusMotion.nextFrame(moves: moves, visible: visible, reduceMotion: reduceMotion) != nil
        var lean = Lean(seed: 7)
        let first = lean.move
        let degrees = stride(from: 0, through: 120, by: WalrusMotion.frameInterval).map { lean.degrees(at: $0, moving: moving) }
        #expect(degrees.allSatisfy { $0 == 0 })
        #expect(lean.move == first)
    }

    @Test("После долгой паузы не догоняет упущенное, а продолжает с того места, где стоял") func longPause() {
        var lean = Lean(seed: 9)
        _ = lean.degrees(at: 1, moving: true)
        let degrees = lean.degrees(at: 100_000, moving: true)
        #expect(degrees == 0)
        #expect(lean.move.start == 100_000)
        #expect(lean.move.from == 0)
    }
}
