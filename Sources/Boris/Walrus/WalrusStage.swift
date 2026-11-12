import BorisCharacter
import BorisCore
import Foundation
import Observation

/// The game around the walrus and what he says. It never touches statuses, events or settings.
@MainActor
@Observable
final class WalrusStage {
    private(set) var play = Play()
    /// A line on screen, with a key of its own, so the same words said twice stay two lines.
    struct ShownLine: Identifiable, Equatable {
        let id: Int
        var line: WalrusSpeech.Line
    }

    /// What he is saying right now, oldest first. Each line leaves on its own time. Whichever surface is open shows them. The menu bar never does.
    private(set) var lines: [ShownLine] = []
    /// The newest line.
    var line: WalrusSpeech.Line? { lines.last?.line }
    /// More than this at once is a wall of text: the oldest goes early.
    static let linesAtOnce = 3
    /// Goes up when a reaction starts, which wakes the pictures.
    private(set) var revision = 0
    var upsideDown = false
    /// Worn for a while over the outfit of the day, after a trick.
    private(set) var costume: Outfit?
    /// The person's own picture, shown in his place for a while after one of their secret words.
    private(set) var picture: URL?

    @ObservationIgnored private var speech = WalrusSpeech()
    @ObservationIgnored private var lineEnds: [Int: Task<Void, Never>] = [:]
    @ObservationIgnored private var lastLineId = 0
    @ObservationIgnored private var costumeEnd: Task<Void, Never>?
    @ObservationIgnored private var pictureEnd: Task<Void, Never>?
    @ObservationIgnored private var sceneRest: Task<Void, Never>?

    /// Seconds between the lines of a scene: long enough to read one, short enough to wait for the next.
    static let sceneGap: TimeInterval = 1.6
    /// How long the witch's hat stays after the spell.
    static let wizardFor: TimeInterval = 8
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
    /// - Parameter secrets: the person's own words. They work with a pack too: they are the person's, not the walrus's.
    /// - Returns: the trick, so the caller can play its sound.
    @discardableResult
    func key(_ key: PlayKey, pose: PoseName, secrets: [SecretWord] = [], now: Date = Date()) -> KeyTrick? {
        guard !isRestricted(pose), let trick = play.key(key, now: now, secrets: secrets.map(\.word)) else { return nil }
        revision += 1
        switch trick {
        case .secret(let word):
            guard let secret = secrets.first(where: { $0.word == word }) else { return trick }
            if let url = secret.picture { show(url, for: secret.seconds) }
            act(secret.lines.map { SceneStep($0) }, now: now)
            return trick
        case .konami:
            wear(.pixel, for: Play.glassesFor)
        case .wizard:
            wear(.witch, for: Self.wizardFor)
        case .name, .hoot, .obviously, .logically:
            break
        }
        // A pack speaks only its own lines.
        guard WalrusArt.shared.pack == nil else { return trick }
        act(WalrusLines.scene(trick), now: now)
        return trick
    }

    /// Says the lines one after another. A new scene cuts the old one short.
    private func act(_ steps: [SceneStep], now: Date) {
        sceneRest?.cancel()
        guard let first = steps.first else { return }
        say(first, now: now)
        let rest = steps.dropFirst()
        guard !rest.isEmpty else { return }
        sceneRest = Task { [weak self] in
            for step in rest {
                try? await Task.sleep(for: .seconds(Self.sceneGap))
                guard !Task.isCancelled, let self else { return }
                self.say(step, now: Date())
            }
        }
    }

    private func say(_ step: SceneStep, now: Date) {
        speech.poked(now: now, fixed: step.text, lines: [])
        if let act = step.act { perform(act, now: now) }
        showLine(now: now)
    }

    private func show(_ url: URL, for seconds: TimeInterval) {
        picture = url
        revision += 1
        pictureEnd?.cancel()
        pictureEnd = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, let self else { return }
            self.picture = nil
            self.revision += 1
        }
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

    /// A new line goes under the ones on screen. The same line again, or one more of a series, stays where it is.
    private func showLine(now: Date) {
        guard let current = speech.line(now: now) else { return }
        if let last = lines.last, last.line.cue == current.cue, last.line.text == current.text,
           current.until == last.line.until || current.count > last.line.count {
            lines[lines.count - 1].line = current
            end(last.id, at: current.until, now: now)
            return
        }
        lastLineId += 1
        lines.append(ShownLine(id: lastLineId, line: current))
        while lines.count > Self.linesAtOnce {
            lineEnds.removeValue(forKey: lines.removeFirst().id)?.cancel()
        }
        end(lastLineId, at: current.until, now: now)
    }

    private func end(_ id: Int, at until: Date, now: Date) {
        lineEnds[id]?.cancel()
        lineEnds[id] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(until.timeIntervalSince(now)))
            guard !Task.isCancelled, let self else { return }
            self.lines.removeAll { $0.id == id }
            self.lineEnds[id] = nil
        }
    }

    private static func isNight(_ now: Date) -> Bool {
        Calendar.current.component(.hour, from: now) < 5
    }

    #if DEBUG
    func sayForSnapshot(_ text: String, count: Int) {
        lines = [ShownLine(id: 0, line: WalrusSpeech.Line(cue: .failure, text: text, count: count, until: .distantFuture))]
    }
    #endif
}
