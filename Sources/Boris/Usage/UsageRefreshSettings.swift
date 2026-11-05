import BorisCore
import SwiftUI

/// The limits group in the connection settings: whether they refresh by themselves, how often, and a button.
struct UsageRefreshSettings: View {
    @Bindable var model: AppModel

    private var settings: AppSettings { model.settings }
    private var enabled: Binding<Bool> { Binding { settings.usageRefreshEnabled } set: { settings.usageRefreshEnabled = $0 } }
    private var minutes: Binding<Int> { Binding { settings.usageRefreshMinutes } set: { settings.usageRefreshMinutes = $0 } }

    private var detail: String {
        var parts: [String] = []
        if settings.usageRefreshEnabled {
            parts.append(L("Every %lld min", settings.usageRefreshMinutes))
        } else {
            parts.append(L("Only with the button"))
        }
        if let fetched = model.world.usage?.fetchedAt {
            parts.append(L("updated %@", WorkFormat.ago(model.now.timeIntervalSince(fetched))))
        }
        if model.usageRefresher.failed { parts.append(L("could not refresh")) }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        SettingsGroup(
            title: L("Limits"),
            footer: L("Boris starts Claude Code for a few seconds and runs its /usage command. He reads no credentials and connects to nothing himself. By itself this only happens while a Claude session is open.")
        ) {
            SettingsRow(title: L("Refresh limits"), detail: detail) {
                Button(L("Refresh now")) { model.usageRefresher.refreshNow() }
                    .buttonStyle(PlainActionStyle(height: 22))
                    .disabled(model.usageRefresher.refreshing)
                Toggle("", isOn: enabled).toggleStyle(.switch).controlSize(.mini).labelsHidden()
            }
            if settings.usageRefreshEnabled {
                SettingsRow(title: L("How often")) {
                    ChoiceBar(
                        options: UsageRefreshPolicy.intervals.map { ($0, L("%lld min", $0)) },
                        selection: minutes,
                        label: L("How often")
                    )
                }
            }
        }
    }
}
