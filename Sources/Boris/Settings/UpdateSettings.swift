import AppKit
import BorisCore
import SwiftUI

/// The group at the bottom of General: the switch, the version and what is known about a newer one.
struct UpdateSettings: View {
    @Bindable var updates: Updates

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? BorisCore.version
    }

    private var automatic: Binding<Bool> {
        Binding { updates.checksAutomatically } set: { updates.setChecksAutomatically($0) }
    }

    var body: some View {
        SettingsGroup(title: L("Updates")) {
            SettingsRow(title: L("Check automatically")) {
                Toggle("", isOn: automatic).toggleStyle(.switch).controlSize(.mini).labelsHidden().disabled(!updates.canCheck)
            }
            if updates.canCheck {
                SettingsRow(title: L("Version %@", version), detail: detail) {
                    trailing
                }
            } else {
                SettingsRow(title: L("Version %@", version), detail: L("This copy was built by hand, so it does not check for updates. Only a released version does.")) {
                    EmptyView()
                }
            }
        }
    }

    private var detail: String {
        switch updates.status {
        case .available(let offer): return "\(L("Version %@ is available", offer.version)). \(L("Claude sessions are not affected by the update."))"
        case .unreachable: return L("No connection. Boris will try again later.")
        default: return ""
        }
    }

    @ViewBuilder private var trailing: some View {
        switch updates.status {
        case .unknown, .unreachable:
            checkButton
        case .checking:
            Text(L("Checking…")).font(.system(size: 12)).foregroundStyle(Palette.text2)
        case .upToDate:
            Text(L("Up to date")).font(.system(size: 12)).foregroundStyle(Palette.text2)
            checkButton
        case .available(let offer):
            UpdateActions(updates: updates, offer: offer, height: 22)
        }
    }

    private var checkButton: some View {
        Button(L("Check now")) { updates.checkNow() }.buttonStyle(PlainActionStyle(height: 22))
    }
}

/// The two buttons of a new version. Nothing downloads before the person says so in the window «Update» opens.
private struct UpdateActions: View {
    var updates: Updates
    var offer: UpdateOffer
    var height: CGFloat = 24

    var body: some View {
        HStack(spacing: 6) {
            Button(L("Update")) { updates.install() }.buttonStyle(PlainActionStyle(primary: true, height: height))
            if let notes = offer.notes {
                Button(L("What's new")) { NSWorkspace.shared.open(notes) }.buttonStyle(PlainActionStyle(height: height))
            }
        }
        // A long detail beside them takes the room it needs from itself, not from the words on the buttons.
        .fixedSize()
    }
}

/// A calm banner above the page, with no window of its own.
struct UpdateNotice: View {
    var updates: Updates

    var body: some View {
        if let offer = updates.offer {
            NoticeBanner(kind: .done, tone: .info, title: L("Version %@ is available", offer.version), text: L("Claude sessions are not affected by the update.")) {
                UpdateActions(updates: updates, offer: offer)
            }
        }
    }
}
