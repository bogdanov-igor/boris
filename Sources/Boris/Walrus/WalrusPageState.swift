import BorisCharacter
import BorisCore
import Observation

/// What the Walrus page is showing. The preview has a stage of its own, so trying things out here changes nothing else.
@MainActor
@Observable
final class WalrusPageState {
    enum Tab: Hashable {
        case outfits, themes, packs
    }

    enum PreviewState: CaseIterable, Hashable {
        case watch, work, wait, happy, hmm, alert, tired, alarm, broken, sleep

        var pose: PoseName {
            switch self {
            case .watch: return .watch
            case .work: return .work
            case .wait: return .wait
            case .happy: return .happy
            case .hmm: return .stopped
            case .alert: return .alert
            case .tired: return .limit
            case .alarm: return .alarm
            case .broken: return .broken
            case .sleep: return .sleep
            }
        }

        /// The line that goes with this state, as on the board.
        var cue: WalrusCue {
            switch self {
            case .wait: return .request
            case .happy: return .finish
            case .tired: return .limit
            case .alarm, .broken, .hmm: return .failure
            case .watch, .work, .alert, .sleep: return .poke
            }
        }
    }

    /// Stands in for the person's project in the sample lines.
    private static let sampleProject = "shop-api"

    var tab = Tab.outfits
    var state = PreviewState.watch
    private(set) var cue = WalrusCue.poke
    private(set) var line: String?
    var packs: [WalrusPack] = []
    var rejection: WalrusPackRejection?
    var importing = false
    let stage = WalrusStage(isPreview: true)
    private var lineLanguage: AppLanguage?

    func choose(state: PreviewState) {
        self.state = state
        choose(cue: state.cue)
    }

    func choose(cue: WalrusCue) {
        self.cue = cue
        let project = cue == .poke || cue == .limit ? nil : Self.sampleProject
        let options = WalrusLines.lines(cue, project: project, pack: WalrusArt.shared.pack, language: Localizer.language)
        let fresh = options.filter { $0 != line }
        line = (fresh.isEmpty ? options : fresh).randomElement()
        lineLanguage = Localizer.language
    }

    /// The line is chosen when the page opens, and again if the language has changed since.
    func prepare() {
        if line == nil || (lineLanguage != nil && lineLanguage != Localizer.language) { choose(cue: cue) }
    }

    #if DEBUG
    func showLineForSnapshot(_ text: String) {
        line = text
    }
    #endif
}
