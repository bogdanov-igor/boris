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
    /// Worn for a while over the outfit of the day, after a trick.
    private(set) var costume: Outfit?

    @ObservationIgnored private var speech = WalrusSpeech()
    @ObservationIgnored private var lineEnd: Task<Void, Never>?
    @ObservationIgnored private var costumeEnd: Task<Void, Never>?
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
    /// - Parameter special: a line of the day, said instead of a random one when the click has no line of its own.
    func poke(pose: PoseName, reduceMotion: Bool, now: Date = Date(), special: String? = nil) -> Bool {
        let turnedAway = play.current(now: now, restricted: false)?.act == .back
        let credits = play.poke(now: now, restricted: isRestricted(pose), night: Self.isNight(now), reduceMotion: reduceMotion)
        revision += 1
        guard !turnedAway else { return credits }
        // A pack speaks only its own lines.
        let pack = WalrusArt.shared.pack
        var fixed = pack == nil ? play.current(now: now, restricted: isRestricted(pose)).flatMap { WalrusLines.reaction($0.act) } : nil
        if pack == nil, play.currentLine(now: now) == .goToSleep { fixed = WalrusLines.lateNight() }
        if pack == nil, fixed == nil { fixed = special }
        speech.poked(now: now, fixed: fixed, lines: WalrusLines.lines(.poke, project: nil, pack: pack, language: Localizer.language))
        showLine(now: now)
        return credits
    }

    func perform(_ act: Act, now: Date = Date()) {
        play.perform(act, now: now)
        revision += 1
    }

    /// A key typed in the main window. Only a finished trick does anything. In alarm or waiting he has better things to say.
    func key(_ key: PlayKey, pose: PoseName, now: Date = Date()) {
        guard !isRestricted(pose), let trick = play.key(key, now: now) else { return }
        revision += 1
        if trick == .konami { wear(.pixel, for: Play.glassesFor) }
        guard WalrusArt.shared.pack == nil else { return }
        speech.poked(now: now, fixed: WalrusLines.trick(trick), lines: [])
        showLine(now: now)
    }

    /// Something he says on his own, with a reaction he already has. A line about the work always comes first.
    /// - Returns: false when it was not the moment.
    func remark(_ text: String, act: Act?, now: Date = Date()) -> Bool {
        guard speech.remark(text, now: now) else { return false }
        if let act { perform(act, now: now) }
        showLine(now: now)
        return true
    }

    private func wear(_ outfit: Outfit, for seconds: TimeInterval) {
        costume = outfit
        costumeEnd?.cancel()
        costumeEnd = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.costume = nil
        }
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
