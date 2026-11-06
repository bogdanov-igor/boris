import AppKit
import BorisCore
import BorisData
import Observation

/// The windows that can hold data of a source.
enum CaptureSurface: Hashable, CaseIterable {
    case main, mini, notch
}

/// What a window holds at this moment.
private struct ShownSources {
    var sources = Set<SourceID>()
    /// Work that nothing says the source of, which may be a forbidden one.
    var unknown = false

    mutating func add(_ environment: WorkEnvironment?) {
        if let source = SourceID(environment) {
            sources.insert(source)
        } else {
            unknown = true
        }
    }

    mutating func add(_ sessions: [WorkSession]) {
        for session in sessions { add(session.environment) }
    }
}

extension AppModel {
    /// After a switch in the settings. Reading means a new look at the logs, and several switches in a row are one change.
    func sourcesChanged(reading: Bool) {
        hooks.applySources()
        // The chat and remote machines have no files here: they cost nothing to change.
        guard reading, !sourceFilter.readsSameFiles(off: settings.sources.readingOff) else { return }
        sourcesRestart?.cancel()
        sourcesRestart = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled, let self else { return }
            self.restartEngine()
            self.losses.sourcesChanged(self)
        }
    }

    /// Whether an event goes out to the Mac, the speakers and Telegram. It stays visible in Boris either way.
    func notifies(about event: BorisEvent) -> Bool {
        let environment = event.environment ?? event.sessionId.flatMap { id in work.sessions.first { $0.id == id }?.environment }
        return settings.sources.notifies(SourceID(environment))
    }

    /// Whether this window must stay out of screenshots, recordings and screen sharing right now.
    func hidesFromCapture(_ surface: CaptureSurface) -> Bool {
        let sources = settings.sources
        guard !sources.captureForbidden.isEmpty else { return false }
        let shown = shownSources(surface)
        return CaptureRule.hides(shown: shown.sources, unknown: shown.unknown, settings: sources)
    }

    private func shownSources(_ surface: CaptureSurface) -> ShownSources {
        var shown = ShownSources()
        func addLive() {
            shown.add(work.sessions)
            for request in hooks.pending {
                if let source = request.source {
                    shown.sources.insert(source)
                } else {
                    shown.add(hooks.queue.session(request.session)?.environment)
                }
            }
        }
        func addTotals() {
            shown.sources.formUnion(usage.sources)
        }
        switch surface {
        case .mini, .notch:
            addLive()
            addTotals()
        case .main:
            // What he says can name a project, on any page.
            if walrus.line != nil { addLive() }
            switch page {
            case .walrus:
                break
            case .now, .spend:
                addLive()
                addTotals()
            case .requests:
                addLive()
                // The history names projects and places in words that cannot be traced back to a source.
                if !hooks.queue.decisions.isEmpty { shown.unknown = true }
            case .activity:
                addLive()
            case .losses:
                for environment in losses.book?.environments ?? [] { shown.add(environment) }
            case .projects:
                switch projectsRoute {
                case .list:
                    shown.add(allSessions)
                    addTotals()
                case .project(let path):
                    shown.add(allSessions.filter { $0.projectPath == path })
                case .session(let id):
                    if let session = session(id) { shown.add(session.environment) }
                }
            }
        }
        return shown
    }
}

/// Takes a window out of captures as soon as it holds data of a forbidden source. It only ever sets this property: nothing here shows a window or moves it.
///
/// It works one way, because macOS does (seen on 26.6): a window can leave captures once in its life. Brought back, it cannot be hidden again, and the system does not say so:
/// the call succeeds and the window stays visible, whether through AppKit or the window server's own call. So a window that has been hidden stays hidden for good,
/// which errs on the safe side, and it is a new window that can be seen again.
@MainActor
final class CaptureKeeper {
    private final class Watch {
        weak var window: NSWindow?
        let surface: CaptureSurface
        var hidden = false

        init(window: NSWindow, surface: CaptureSurface) {
            self.window = window
            self.surface = surface
        }
    }

    private var watches: [Watch] = []
    private var following = false
    var hides: (CaptureSurface) -> Bool = { _ in false }

    /// Takes effect at once, so call it before the window goes on screen. Can be called again for a window that was created anew, as a popover's may be.
    func watch(_ window: NSWindow, as surface: CaptureSurface) {
        if watches.contains(where: { $0.window === window }) { return }
        watches.removeAll { $0.window == nil || $0.surface == surface }
        watches.append(Watch(window: window, surface: surface))
        if following {
            apply()
        } else {
            following = true
            follow()
        }
    }

    /// Whether this window has been taken out of captures, so that only a new one can be seen in them again.
    func wasHidden(_ window: NSWindow) -> Bool {
        watches.contains { $0.window === window && $0.hidden }
    }

    private func follow() {
        withObservationTracking {
            apply()
        } onChange: { [weak self] in
            Task { @MainActor in self?.follow() }
        }
    }

    private func apply() {
        for watch in watches where !watch.hidden && hides(watch.surface) {
            watch.hidden = true
            watch.window?.sharingType = .none
        }
    }
}
