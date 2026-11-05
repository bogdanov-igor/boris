import AppKit
import BorisCore
import BorisData
import SwiftUI

/// Takes the person to a session. It only opens things and never sends anything on its own.
@MainActor
enum SessionNavigator {
    /// A session with no process or no window of its own has nowhere to go.
    /// - Parameter pid: of its process. Nil when it has none on this Mac.
    static func canOpen(_ session: WorkSession?, pid: Int32?) -> Bool {
        switch session?.environment {
        case .vsCode, .cursor, .claudeDesktop, .cowork: return true
        case .terminal: return pid != nil
        case .program, .chat, .insideClaude, .remote, nil: return false
        }
    }

    static func open(_ session: WorkSession, model: AppModel) {
        // A session that has ended has no process, and its old number may belong to another program by now.
        let process = model.world.sessions.first { $0.sessionId == session.id }?.pid
        let owner = process.flatMap { $0 > 0 ? ownerApp(pid: $0) : nil }
        let plan = SessionJump.plan(
            environment: session.environment,
            sessionId: session.id,
            cwd: session.cwd,
            folderExists: session.cwd.map { FileManager.default.fileExists(atPath: $0) } ?? false,
            owner: owner?.bundleIdentifier
        )
        switch plan {
        case .link(let url, let folder):
            if let folder {
                NSWorkspace.shared.open(folder)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { NSWorkspace.shared.open(url) }
            } else {
                NSWorkspace.shared.open(url)
            }
        case .activateOwner:
            activate(owner)
        case .activateOwnerAndCopyId:
            activate(owner)
            copy(session.id)
            tell(L("Session ID copied."))
        case .openApp(let bundleId):
            openApp(bundleId)
        case .openTerminal:
            openTerminal()
        case .noWindow:
            copy(session.id)
            tell(L("This session has no window to open. Session ID copied."))
        case .folderGone:
            copy(session.id)
            tell(L("The project folder is gone. Session ID copied."))
        }
    }

    /// Walks up the process tree to the first real application.
    static func ownerApp(pid: Int32) -> NSRunningApplication? {
        for process in ProcessInspector.ancestors(of: pid) {
            if let app = NSRunningApplication(processIdentifier: process), app.activationPolicy == .regular { return app }
        }
        return nil
    }

    /// Since macOS 14 an application comes forward only when the active one gives way.
    private static func activate(_ app: NSRunningApplication?) {
        guard let app else { return }
        NSApp.yieldActivation(to: app)
        app.activate()
    }

    private static func openApp(_ bundleId: String) {
        if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) {
            NSWorkspace.shared.open(app)
        } else {
            tell(L("This application is not installed."))
        }
    }

    /// A session inside tmux has no terminal up its process tree, so whichever one is open is the best guess.
    private static func openTerminal() {
        let known = ["com.googlecode.iterm2", "com.mitchellh.ghostty", "dev.warp.Warp-Stable", "net.kovidgoyal.kitty", "com.github.wez.wezterm", "org.alacritty", "com.apple.Terminal"]
        for id in known {
            if let running = NSRunningApplication.runningApplications(withBundleIdentifier: id).first {
                activate(running)
                return
            }
        }
        openApp("com.apple.Terminal")
    }

    private static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private static func tell(_ text: String) {
        let alert = NSAlert()
        alert.messageText = text
        alert.alertStyle = .informational
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}

/// «Открыть терминал», «Открыть в VS Code» and so on, for wherever a session is shown.
struct OpenSessionButton: View {
    var model: AppModel
    var session: WorkSession
    var height: CGFloat = 26

    var body: some View {
        Button(SessionJump.title(session.environment)) { SessionNavigator.open(session, model: model) }
            .buttonStyle(PlainActionStyle(height: height))
    }
}
