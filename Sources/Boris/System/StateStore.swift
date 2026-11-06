import Foundation
import BorisCore
import BorisData

/// What Boris remembers between launches. Ids, names and numbers only: never prompts or results.
struct AppState: Codable, Sendable, Equatable {
    var runs: [String: RunMemory] = [:]
    var detector = DetectorMemory()
    var awards = AwardTracker()
    var firstLaunch: Date?
    var quiet = QuietMode()
    /// The first-run offer to connect answers was closed.
    var connectOfferDismissed = false
    /// The notice about the icon behind the notch was seen.
    var iconNoticeSeen = false
}

/// Reads and writes `~/Library/Application Support/Boris`. Writes are atomic and off the main thread.
final class StateStore: Sendable {
    let folder: URL
    private let queue = DispatchQueue(label: "app.boris.state", qos: .utility)

    init(folder: URL = BorisPaths.support) {
        self.folder = folder
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            AppLog.note(.fileWriteFailed, .word(.ownFolder), .failure(error))
        }
    }

    private var stateURL: URL { folder.appendingPathComponent("state.json") }

    /// A broken file means every run counts as already seen, and the app simply goes on.
    func loadState() -> AppState {
        guard let data = try? Data(contentsOf: stateURL) else { return AppState() }
        guard let state = try? JSONDecoder().decode(AppState.self, from: data) else {
            AppLog.note(.fileBroken, .word(.stateFile))
            return AppState()
        }
        return state
    }

    func save(_ state: AppState) {
        write(state, to: stateURL)
    }

    private func write<T: Encodable & Sendable>(_ value: T, to url: URL) {
        queue.async {
            guard let data = try? JSONEncoder().encode(value) else { return }
            do {
                try data.write(to: url, options: .atomic)
            } catch {
                AppLog.note(.fileWriteFailed, .word(.stateFile), .failure(error))
            }
        }
    }

    /// Waits until queued writes are done. Used on quit, so nothing is lost.
    func flush() {
        queue.sync {}
    }
}
