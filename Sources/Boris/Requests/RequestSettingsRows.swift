import AppKit
import BorisCore
import SwiftUI

/// The wait and the keys, in the Connections section.
struct RequestSettingsRows: View {
    @Bindable var model: AppModel

    /// All shorter than `HookController.hookLimit` and `HookState.waitingExpiry`, so a request that ran out still shows its session waiting.
    static let waits = [30, 60, 120, 300]

    private var settings: AppSettings { model.settings }

    private var wait: Binding<Int> {
        Binding { settings.permissionWaitSeconds } set: { seconds in
            settings.permissionWaitSeconds = seconds
            model.hooks.applyWait()
        }
    }

    var body: some View {
        SettingsRow(title: L("Time to wait for an answer"), detail: L("After that, answer in Claude")) {
            ChoiceBar(options: Self.waits.map { ($0, RequestWords.waitChoice($0)) }, selection: wait, label: L("Time to wait for an answer")).fixedSize()
        }
        SettingsRow(
            title: L("Allow key"),
            detail: L("Works only while a card is on screen. At any other time the combination reaches the active app."),
            warning: model.hooks.keysTaken ? L("A key is taken by another app. Choose another combination, or answer with the buttons.") : ""
        ) {
            RequestKeyField(model: model, label: settings.allowKey.label) { combo in
                guard combo != settings.denyKey, combo != settings.hotKey else { return false }
                settings.allowKey = combo
                return true
            }
        }
        SettingsRow(title: L("Deny key")) {
            RequestKeyField(model: model, label: settings.denyKey.label) { combo in
                guard combo != settings.allowKey, combo != settings.hotKey else { return false }
                settings.denyKey = combo
                return true
            }
        }
    }
}

/// Takes the next combination pressed after a click. Enter is refused with any modifier, because Enter must never answer.
private struct RequestKeyField: View {
    @Bindable var model: AppModel
    var label: String
    /// False means the combination is already used by another key of Boris.
    var choose: (HotKeyCombo) -> Bool

    @State private var recording = false
    @State private var refused = false
    @State private var monitor: Any?

    var body: some View {
        Button {
            recording ? stop() : start()
        } label: {
            Text(recording ? L("Press keys…") : label)
                .font(.system(size: 12, design: .monospaced))
                .padding(.horizontal, 10)
                .frame(height: 22)
                .background(RoundedRectangle(cornerRadius: DesignMetrics.radiusMedium).fill(Palette.button))
                .overlay(
                    RoundedRectangle(cornerRadius: DesignMetrics.radiusMedium)
                        .strokeBorder(refused ? Palette.red : Palette.buttonBorder, lineWidth: refused ? 1.5 : 0.5)
                )
        }
        .buttonStyle(.plain)
        .onDisappear(perform: stop)
    }

    private func start() {
        recording = true
        refused = false
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 {
                stop()
                return nil
            }
            guard let combo = HotKeyCombo(event: event) else { return nil }
            guard !combo.isEnter, choose(combo) else {
                refused = true
                return nil
            }
            model.hooks.applyKeys()
            stop()
            return nil
        }
    }

    private func stop() {
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
