import AppKit
import BorisCore
import BorisData

/// Takes the person to where a request can be answered in Claude. It only opens things and never sends anything on its own.
@MainActor
enum SessionOpener {
    private static let claudeDesktop = "com.anthropic.claudefordesktop"

    /// A session with no process or no window of its own has nowhere to go.
    static func canOpen(_ session: WorkSession?, pid: Int32?) -> Bool {
        switch session?.environment {
        case .vsCode, .cursor, .claudeDesktop, .cowork: return true
        case .terminal: return pid != nil
        case .program, .chat, .insideClaude, .remote, nil: return false
        }
    }

    static func open(_ session: WorkSession, pid: Int32?) {
        switch session.environment {
        case .vsCode: openEditor(scheme: "vscode", session: session)
        case .cursor: openEditor(scheme: "cursor", session: session)
        case .claudeDesktop, .cowork:
            if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: claudeDesktop) { NSWorkspace.shared.open(app) }
        case .terminal:
            if let pid { ownerApp(pid: pid)?.activate() }
        case .program, .chat, .insideClaude, .remote, nil:
            break
        }
    }

    /// The link opens in the focused window, so the project's window comes first.
    private static func openEditor(scheme: String, session: WorkSession) {
        var link = URLComponents()
        link.scheme = scheme
        link.host = "anthropic.claude-code"
        link.path = "/open"
        link.queryItems = [URLQueryItem(name: "session", value: session.id)]
        guard let url = link.url else { return }
        var folder = URLComponents()
        folder.scheme = scheme
        folder.host = "file"
        folder.path = session.cwd ?? ""
        guard session.cwd != nil, let folderURL = folder.url else {
            NSWorkspace.shared.open(url)
            return
        }
        NSWorkspace.shared.open(folderURL)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { NSWorkspace.shared.open(url) }
    }

    /// Walks up the process tree to the first real application.
    private static func ownerApp(pid: Int32) -> NSRunningApplication? {
        var current: Int32? = pid
        var hops = 0
        while let value = current, value > 1, hops < 32 {
            if let app = NSRunningApplication(processIdentifier: value), app.activationPolicy == .regular { return app }
            current = ProcessInspector.parent(pid: value)
            hops += 1
        }
        return nil
    }
}
