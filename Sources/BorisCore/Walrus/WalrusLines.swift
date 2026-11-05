import Foundation

/// What the walrus can have something to say about. The raw values are the keys in a pack's line files.
public enum WalrusCue: String, CaseIterable, Sendable, Hashable, Codable {
    case poke, request, finish, failure, limit

    /// Stopping is the person's own doing and silence has its pose, so neither gets a line.
    public init?(event: EventKind) {
        switch event {
        case .waiting: self = .request
        case .completed, .sessionFinished: self = .finish
        case .failed, .allAgentsFailed, .interrupted, .sessionError, .completedWithErrors: self = .failure
        case .limitNear, .limitReached: self = .limit
        case .stopped, .silent: return nil
        }
    }
}

/// The built-in walrus's lines: Boris in the character of Churchill. The Russian is in `Resources/Strings/walrus-lines.json`.
public enum WalrusLines {
    /// Whoever speaks now: a pack, or the walrus himself.
    public static func lines(_ cue: WalrusCue, project: String?, pack: WalrusPack?, language: AppLanguage) -> [String] {
        pack?.lines(for: cue, project: project, language: language.rawValue) ?? builtIn(cue, project: project)
    }

    public static func builtIn(_ cue: WalrusCue, project: String?) -> [String] {
        switch cue {
        case .poke:
            return [
                L("We shall never surrender."),
                L("We shall answer in the notch, we shall answer in the menu bar. We shall never surrender."),
                L("Never have so many tokens been spent by so few agents."),
                L("Success is not final, failure is not fatal."),
                L("If you are going through hell, keep going."),
                L("My tastes are simple. I am easily satisfied with the best."),
                L("The cigar has gone out. The watch has not."),
                L("Monocle in place. We may proceed."),
                L("I do not remove the bowler, not even in my sleep."),
                L("Who smokes a cigar on duty? I do."),
                L("I may be wrong. I shall not retreat."),
                L("You may press. I shall not give way."),
            ]
        case .request:
            let general = [
                L("You are awaited."),
                L("You are awaited. Decisions, like cigars, do not keep in the damp."),
                L("We go no further without your decision."),
                L("They await your word. I shall mind the cigar."),
            ]
            guard let project else { return general }
            return general + [L("In %@ they await your word.", project)]
        case .finish:
            let general = [
                L("Never have so many tokens been spent by so few agents."),
                L("The job is done. One may light up."),
                L("A victory. A modest one, but ours."),
                L("We have prevailed."),
            ]
            guard let project else { return general }
            return general + [L("%@ is done. No speeches.", project), L("%@ is finished. I am satisfied.", project)]
        case .failure:
            if let project {
                return [
                    L("An agent fell in %@. This is not the end. It is not even the beginning of the end.", project),
                    L("A failure in %@. We shall stand.", project),
                    L("Something collapsed in %@. I kept hold of the monocle.", project),
                ]
            }
            return [
                L("An agent has fallen. This is not the end. It is not even the beginning of the end."),
                L("A failure. We shall stand."),
                L("Something collapsed. I kept hold of the monocle."),
                L("Failure is not fatal. But it is worth a look."),
            ]
        case .limit:
            return [
                L("The limit is at hand. I have nothing to offer but tokens, toil, tears and sweat."),
                L("Tokens are running low. So are the cigars."),
                L("We have fought for every token. The limit does not sleep."),
                L("The limit is upon us. We shall economise, not surrender."),
            ]
        }
    }

    /// The line that goes with a reaction to a run of clicks, if it has one.
    public static func reaction(_ act: Act) -> String? {
        switch act {
        case .hoot: return L("Ahem.")
        case .annoyed: return L("Enough. I am on duty.")
        case .back: return L("I turn my back. It is a position.")
        case .dizzy: return L("My head is spinning. I hold my position.")
        case .yawn, .poke, .wink, .spin: return nil
        }
    }

    public static func lateNight() -> String {
        L("It is night. I should be asleep by now.")
    }

    /// The words under the walrus: how things stand, in his voice. The numbers stay exact.
    public static func standing(mood: Mood, waiting: Int) -> String {
        switch mood {
        case .alarm: return L("Something has fallen. I am at my post.")
        case .broken: return L("I cannot read Claude's data. I am looking into it.")
        case .waiting: return L("Awaiting your word: %lld", waiting)
        case .tired: return L("The limit is at hand. I am saving my strength.")
        case .alert: return L("No news for a long while. I am on my guard.")
        case .happy: return L("The job is done.")
        case .hmm: return L("Not everything got done. Hm.")
        case .working(let agents):
            return agents > 1 ? L("Agents on duty: %lld", agents) : L("Work is under way. I am keeping an eye on it.")
        case .sleeping: return L("All quiet. I keep watch with my eyes shut.")
        }
    }
}
