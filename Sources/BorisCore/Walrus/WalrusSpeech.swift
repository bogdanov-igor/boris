import Foundation

/// Decides when the walrus says something, so a wave of events stays one line. It knows nothing about prompts or results: only a cue and a project name.
public struct WalrusSpeech: Sendable, Equatable {
    public struct Line: Sendable, Equatable {
        public var cue: WalrusCue
        public var text: String
        /// How many events of a series this line stands for.
        public var count: Int
        public var until: Date

        public init(cue: WalrusCue, text: String, count: Int = 1, until: Date) {
            self.cue = cue
            self.text = text
            self.count = count
            self.until = until
        }
    }

    public static let shownFor: TimeInterval = 7
    /// Events of one kind this close together are one series.
    public static let seriesGap: TimeInterval = 20
    /// Different events wait their turn this long. Only a failure does not.
    public static let quietGap: TimeInterval = 30
    /// A quick run of clicks must not flicker through the lines.
    public static let pokeGap: TimeInterval = 1.5

    private var current: Line?
    private var lastEventLine = Date.distantPast
    private var lastPokeLine = Date.distantPast
    private var lastHeard: [WalrusCue: Date] = [:]
    private var seriesProject: String?
    private var lastText: [WalrusCue: String] = [:]

    public init() {}

    public func line(now: Date) -> Line? {
        guard let current, now < current.until else { return nil }
        return current
    }

    /// - Parameter lines: what can be said about this cue, for a project or, with nil, in general.
    public mutating func hear(_ cue: WalrusCue, project: String?, now: Date, lines: (String?) -> [String], pick: (Int) -> Int = { Int.random(in: 0..<$0) }) {
        let previous = lastHeard[cue]
        lastHeard[cue] = now
        if let previous, now.timeIntervalSince(previous) < Self.seriesGap {
            guard var line = current, line.cue == cue else { return }
            line.count += 1
            line.until = now.addingTimeInterval(Self.shownFor)
            // A series over several projects cannot name just one of them.
            if project != seriesProject, seriesProject != nil, let general = choose(lines(nil), cue: cue, pick: pick) {
                line.text = general
                seriesProject = nil
            }
            current = line
            return
        }
        guard cue == .failure || now.timeIntervalSince(lastEventLine) >= Self.quietGap, let text = choose(lines(project), cue: cue, pick: pick) else { return }
        lastEventLine = now
        seriesProject = project
        current = Line(cue: cue, text: text, until: now.addingTimeInterval(Self.shownFor))
    }

    /// The person asked for it, so there is no waiting for a turn. `fixed` is a line that belongs to a reaction.
    public mutating func poked(now: Date, fixed: String? = nil, lines: [String], pick: (Int) -> Int = { Int.random(in: 0..<$0) }) {
        guard fixed != nil || now.timeIntervalSince(lastPokeLine) >= Self.pokeGap, let text = fixed ?? choose(lines, cue: .poke, pick: pick) else { return }
        lastPokeLine = now
        current = Line(cue: .poke, text: text, until: now.addingTimeInterval(Self.shownFor))
    }

    /// Something he says on his own. It never pushes aside a line on screen, nor comes right after one about the work.
    /// - Returns: false when it was not the moment, so it can be tried again later.
    public mutating func remark(_ text: String, now: Date) -> Bool {
        guard line(now: now) == nil, now.timeIntervalSince(lastEventLine) >= Self.quietGap else { return false }
        current = Line(cue: .poke, text: text, until: now.addingTimeInterval(Self.shownFor))
        return true
    }

    /// Never the same line twice in a row, if there is another one.
    private mutating func choose(_ lines: [String], cue: WalrusCue, pick: (Int) -> Int) -> String? {
        let fresh = lines.count > 1 ? lines.filter { $0 != lastText[cue] } : lines
        guard !fresh.isEmpty else { return nil }
        let text = fresh[min(max(pick(fresh.count), 0), fresh.count - 1)]
        lastText[cue] = text
        return text
    }
}
