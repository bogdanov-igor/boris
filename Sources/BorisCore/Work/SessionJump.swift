import Foundation

/// How to take the person to a session. This only decides, the app does it.
public enum SessionJump: Sendable, Equatable {
    /// A link the editor understands. The folder comes first, because the link opens in whichever window has the focus.
    case link(URL, folder: URL?)
    /// Bring forward the application that owns the session's process.
    case activateOwner
    case openApp(bundleId: String)
    /// A terminal session whose window cannot be found, such as one inside tmux.
    case openTerminal
    /// An editor Boris has no link for: bring it forward and leave the id on the clipboard.
    case activateOwnerAndCopyId
    /// There is no window to open, so the id goes on the clipboard and Boris says so.
    case noWindow
    case folderGone

    public static let claudeDesktop = "com.anthropic.claudefordesktop"

    /// Which link scheme each editor registers. All of them run the same extension.
    private static let editorSchemes = [
        "com.microsoft.VSCode": "vscode",
        "com.microsoft.VSCodeInsiders": "vscode-insiders",
        "com.todesktop.230313mzl4w4u92": "cursor",
    ]

    /// - Parameter owner: the first real application up the session's process tree, nil when there is none.
    public static func plan(environment: WorkEnvironment?, sessionId: String, cwd: String?, folderExists: Bool, owner: String?) -> SessionJump {
        switch environment {
        case .claudeDesktop, .cowork, .chat:
            return .openApp(bundleId: claudeDesktop)
        case .program, .insideClaude, .remote:
            return owner == nil ? .noWindow : .activateOwner
        case .vsCode, .cursor:
            guard cwd == nil || folderExists else { return .folderGone }
            // The owner is what really runs, as an editor may report itself as another one.
            let scheme: String
            if let owner {
                guard let known = editorSchemes[owner] else { return .activateOwnerAndCopyId }
                scheme = known
            } else {
                scheme = environment == .cursor ? "cursor" : "vscode"
            }
            guard let url = link(scheme: scheme, sessionId: sessionId) else { return .noWindow }
            return .link(url, folder: cwd.flatMap { folderLink(scheme: scheme, path: $0) })
        case .terminal, nil:
            return owner == nil ? (environment == nil ? .noWindow : .openTerminal) : .activateOwner
        }
    }

    public static func link(scheme: String, sessionId: String) -> URL? {
        var link = URLComponents()
        link.scheme = scheme
        link.host = "anthropic.claude-code"
        link.path = "/open"
        link.queryItems = [URLQueryItem(name: "session", value: sessionId)]
        return link.url
    }

    private static func folderLink(scheme: String, path: String) -> URL? {
        var link = URLComponents()
        link.scheme = scheme
        link.host = "file"
        link.path = path
        return link.url
    }

    /// The words on the button that does this.
    public static func title(_ environment: WorkEnvironment?) -> String {
        switch environment {
        case .terminal: return L("Open terminal")
        case .vsCode: return L("Open in VS Code")
        case .cursor: return L("Open in Cursor")
        case .claudeDesktop, .cowork, .chat: return L("Open Claude Desktop")
        case .program, .insideClaude, .remote, nil: return L("Open session")
        }
    }
}
