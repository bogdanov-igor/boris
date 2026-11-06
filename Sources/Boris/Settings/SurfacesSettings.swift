import AppKit
import BorisCore
import SwiftUI

struct SurfacesSettings: View {
    @Bindable var model: AppModel
    @State private var screens = SurfaceScreens.current()

    private var settings: AppSettings { model.settings }
    private var switches: SurfaceSwitches { settings.surfaces }

    var body: some View {
        SettingsGroup {
            row(.icon, title: L("Menu bar icon"))
            row(.notch, title: L("Notch"), detail: Self.notchDetail(switches, hotKeyWorks: model.hotKeyWorks))
            row(.mini, title: L("Mini window"), detail: !switches.icon && switches.mini && model.hotKeyWorks ? L("Without the icon it opens with %@.", settings.hotKey.label) : "")
        }
        SettingsGroup(footer: L("The main screen, a particular monitor, or wherever the cursor is.")) {
            SettingsRow(title: L("Screen"), warning: screenGone.map { L("%@ is not connected. Until it returns, the notch or panel is on the main screen.", $0) } ?? "", warningIsProblem: false) {
                Picker("", selection: choice) {
                    Text(L("Follow the cursor")).tag(SurfaceScreenChoice.followCursor.key)
                    Text(L("Main screen")).tag(SurfaceScreenChoice.main.key)
                    if !screens.isEmpty || screenGone != nil { Divider() }
                    ForEach(screens) { screen in
                        Text(screen.name).tag(screen.id)
                    }
                    if let screenGone {
                        Text(L("%@ (not connected)", screenGone)).tag(settings.surfaceScreen.key)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .controlSize(.small)
                .fixedSize()
                .accessibilityLabel(L("Screen"))
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
            screens = SurfaceScreens.current()
        }
    }

    private func row(_ surface: Surface, title: String, detail: String = "") -> some View {
        let locked = switches[surface] && !switches.canTurnOff(surface, hotKeyWorks: model.hotKeyWorks)
        return SettingsRow(title: title, detail: detail, warning: locked ? lockedReason : "", warningIsProblem: false) {
            Toggle("", isOn: Binding { switches[surface] } set: { on in settings.surfaces[surface] = on })
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
                .disabled(locked)
                .accessibilityLabel(title)
        }
    }

    /// As the last way in, the panel stays on a full bar, and on a hidden one only the top edge of the screen opens it. Nothing on screen tells that, so the words have to.
    static func notchDetail(_ switches: SurfaceSwitches, hotKeyWorks: Bool) -> String {
        guard switches.canTurnOff(.notch, hotKeyWorks: hotKeyWorks) else {
            return L("On a Mac without a notch and on an external monitor, a small panel in the menu bar takes its place. If the menu bar is hidden, move the pointer to the very top of the screen to open it.")
        }
        return L("On a Mac without a notch and on an external monitor, a small panel in the menu bar takes its place. If the menu bar is hidden or full, it appears only when Claude asks for something.")
    }

    private var lockedReason: String {
        // Everything else being off, the mini window would be left, but it opens only with a hotkey that does not work.
        if switches.mini, !model.hotKeyWorks {
            return L("This is the last way to open Boris, so it stays on. Without the icon the mini window opens only with the hotkey, and the hotkey is not working now.")
        }
        return L("This is the last way to open Boris, so it stays on.")
    }

    /// The name of the chosen monitor, if it is not connected.
    private var screenGone: String? {
        guard case .screen(let id, let name) = settings.surfaceScreen, !screens.contains(where: { $0.id == id }) else { return nil }
        return name
    }

    private var choice: Binding<String> {
        Binding {
            settings.surfaceScreen.key
        } set: { key in
            guard key != settings.surfaceScreen.key else { return }
            if key == SurfaceScreenChoice.followCursor.key {
                settings.surfaceScreen = .followCursor
            } else if key == SurfaceScreenChoice.main.key {
                settings.surfaceScreen = .main
            } else if let screen = screens.first(where: { $0.id == key }) {
                settings.surfaceScreen = .screen(id: screen.id, name: screen.name)
            }
        }
    }
}
