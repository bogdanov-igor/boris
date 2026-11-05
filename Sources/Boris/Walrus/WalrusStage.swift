import BorisCharacter
import BorisCore
import Foundation
import Observation

/// The game around the walrus and what he says. It never touches statuses, events or settings.
@MainActor
@Observable
final class WalrusStage {
    private(set) var play = Play()
    /// What he is saying right now. Whichever surface is open shows it. The menu bar never does.
    private(set) var line: WalrusSpeech.Line?
    /// Goes up when a reaction starts, which wakes the pictures.
    private(set) var revision = 0
    var upsideDown = false

    @ObservationIgnored private var speech = WalrusSpeech()
    @ObservationIgnored private var lineEnd: Task<Void, Never>?
    private let isPreview: Bool

    /// - Parameter isPreview: on the Walrus page any reaction may play over any state, because the person asked to see it.
    init(isPreview: Bool = false) {
        self.isPreview = isPreview
    }

    /// In alarm or waiting he has something to say, so a poke only squashes him for a moment.
    func isRestricted(_ pose: PoseName) -> Bool {
        !isPreview && (pose == .alarm || pose == .wait)
    }

    /// Returns true when the person has poked him so many times that the credits should roll.
    func poke(pose: PoseName, reduceMotion: Bool, now: Date = Date()) -> Bool {
        let turnedAway = play.current(now: now, restricted: false)?.act == .back
        let credits = play.poke(now: now, restricted: isRestricted(pose), night: Self.isNight(now), reduceMotion: reduceMotion)
        revision += 1
        guard !turnedAway else { return credits }
        // A pack speaks only its own lines.
        let pack = WalrusArt.shared.pack
        var fixed = pack == nil ? play.current(now: now, restricted: isRestricted(pose)).flatMap { WalrusLines.reaction($0.act) } : nil
        if pack == nil, play.currentLine(now: now) == .goToSleep { fixed = WalrusLines.lateNight() }
        speech.poked(now: now, fixed: fixed, lines: WalrusLines.lines(.poke, project: nil, pack: pack, language: Localizer.language))
        showLine(now: now)
        return credits
    }

    func perform(_ act: Act, now: Date = Date()) {
        play.perform(act, now: now)
        revision += 1
    }

    /// An event of the work. Most events pass in silence: that is the point of `WalrusSpeech`.
    func hear(_ event: BorisEvent) {
        guard let cue = WalrusCue(event: event.kind) else { return }
        speech.hear(cue, project: event.project, now: event.at) { project in
            WalrusLines.lines(cue, project: project, pack: WalrusArt.shared.pack, language: Localizer.language)
        }
        showLine(now: event.at)
    }

    private func showLine(now: Date) {
        line = speech.line(now: now)
        lineEnd?.cancel()
        guard let until = line?.until else { return }
        lineEnd = Task { [weak self] in
            try? await Task.sleep(for: .seconds(until.timeIntervalSince(now)))
            guard !Task.isCancelled else { return }
            self?.line = nil
        }
    }

    private static func isNight(_ now: Date) -> Bool {
        Calendar.current.component(.hour, from: now) < 5
    }

    #if DEBUG
    func sayForSnapshot(_ text: String, count: Int) {
        line = WalrusSpeech.Line(cue: .failure, text: text, count: count, until: .distantFuture)
    }
    #endif
}
