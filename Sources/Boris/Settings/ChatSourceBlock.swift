import AppKit
import BorisCore
import BorisData
import SwiftUI

/// Plain chat in Claude Desktop: off until the person agrees, after being told what agreeing means.
struct ChatSourceBlock: View {
    @Bindable var model: AppModel
    /// The explanation is open: the switch is on, but nothing has been agreed to yet.
    @State private var explaining: Bool

    init(model: AppModel, explaining: Bool = false) {
        self.model = model
        _explaining = State(initialValue: explaining)
    }

    private var connection: ChatConnection { model.chat.tracker.connection }

    private var isOn: Binding<Bool> {
        Binding {
            // On only while Boris really may look: the consent and the source together.
            explaining || (model.settings.chatConsent && model.settings.sources.reads(.chat))
        } set: { wanted in
            if wanted {
                explaining = true
            } else {
                explaining = false
                model.setChatConsent(false)
            }
        }
    }

    private var detail: String {
        if explaining { return "" }
        switch connection {
        case .notConnected: return L("Not connected. To see that an answer is ready, Boris needs the Accessibility permission.")
        case .needsPermission: return L("Waiting for the permission. Turn Boris on in System Settings, under Privacy & Security, Accessibility.")
        case .appClosed: return L("Connected. Claude Desktop is closed right now.")
        case .cannotSee, .connected: return L("Connected. Boris tells you when an answer is ready while Claude Desktop is in the background.")
        }
    }

    private var warning: String {
        connection == .cannotSee && !explaining ? L("Boris cannot see into the Claude Desktop window right now, so it may miss an answer.") : ""
    }

    var body: some View {
        SettingsGroup(footer: L("The text of chats is never read, and their tokens and actions are not available. Claude Desktop has notifications of its own, so this helps when those are off.")) {
            SettingsRow(title: L("Claude chat"), detail: detail, warning: warning) {
                Toggle("", isOn: isOn).toggleStyle(.switch).controlSize(.mini).labelsHidden().accessibilityLabel(L("Claude chat"))
            }
            if explaining {
                explanation
            } else if connection == .needsPermission {
                SettingsRow(title: L("Accessibility permission")) {
                    Button(L("Open System Settings")) { openSystemSettings() }.buttonStyle(PlainActionStyle(height: 22))
                }
            }
        }
    }

    private var explanation: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L("Every few seconds, while Claude Desktop is in the background, Boris will look in its window for one thing: whether the button that stops an answer is on screen. Boris does not read your chats and presses nothing. Claude Desktop may run a little slower while this is on."))
                .font(.system(size: 12))
                .lineSpacing(2)
                .foregroundStyle(Palette.text2)
                .fixedSize(horizontal: false, vertical: true)
            Text(L("This needs the Accessibility permission. macOS will ask for it next, and you can take it back in System Settings at any time."))
                .font(.system(size: 12))
                .lineSpacing(2)
                .foregroundStyle(Palette.text2)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button(L("Continue")) {
                    explaining = false
                    model.setChatConsent(true)
                }
                .buttonStyle(PlainActionStyle(primary: true, height: 22))
                Button(L("Not now")) { explaining = false }.buttonStyle(PlainActionStyle(height: 22))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .top) { Rectangle().fill(Palette.separator).frame(height: 1) }
    }

    private func openSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") { NSWorkspace.shared.open(url) }
    }
}

extension AppModel {
    /// The one place consent is given or taken back.
    func setChatConsent(_ on: Bool) {
        settings.chatConsent = on
        // Agreeing is what turns the chat on: its source is off by default, and without it nothing would ever be said.
        settings.sources.setChat(on: on)
        sourcesChanged(reading: false)
        if on { chat.askForPermission() }
    }
}
