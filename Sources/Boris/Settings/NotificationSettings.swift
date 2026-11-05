import AppKit
import BorisCore
import BorisData
import SwiftUI

struct NotificationSettings: View {
    @Bindable var model: AppModel

    private var settings: AppSettings { model.settings }

    var body: some View {
        if model.notifications.macDenied { deniedNotice }
        EventTable(settings: settings, telegramConnected: !settings.notifications.telegramChat.isEmpty)
            // The person may have just changed this in System Settings.
            .onAppear { model.notifications.refreshPermission() }
        SettingsGroup {
            thresholdRow(
                L("Limit threshold"),
                detail: L("When to warn that a limit is close"),
                options: [50, 60, 70, 75, 80, 85, 90, 95],
                word: { WorkFormat.percent(Double($0)) },
                selection: Binding { settings.notifications.limitNearPercent } set: { settings.notifications.limitNearPercent = $0 }
            )
            thresholdRow(
                L("Silence threshold"),
                detail: L("How much quiet makes a session silent"),
                options: [5, 10, 12, 15, 20, 30, 60],
                word: { WorkFormat.duration(TimeInterval($0) * 60) },
                selection: Binding { settings.silenceMinutes } set: { settings.silenceMinutes = $0 }
            )
            QuietRow(model: model)
            VoiceRow(model: model)
        }
        TelegramGroup(model: model)
    }

    private var deniedNotice: some View {
        SettingsGroup {
            SettingsRow(title: L("Mac notifications are not allowed"), detail: L("Banners stay off until you allow them in System Settings. Sounds and Telegram work anyway.")) {
                Button(L("Open System Settings")) {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") { NSWorkspace.shared.open(url) }
                }
                .buttonStyle(PlainActionStyle(height: 22))
            }
        }
    }

    private func thresholdRow(_ title: String, detail: String, options: [Int], word: @escaping (Int) -> String, selection: Binding<Int>) -> some View {
        SettingsRow(title: title, detail: detail) {
            Picker(title, selection: Binding {
                selection.wrappedValue
            } set: {
                selection.wrappedValue = $0
                model.thresholdsChanged()
            }) {
                // What the person set by other means stays on the list.
                ForEach(options.contains(selection.wrappedValue) ? options : (options + [selection.wrappedValue]).sorted(), id: \.self) { value in
                    Text(word(value)).tag(value)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .controlSize(.small)
            .fixedSize()
        }
    }
}

/// Which event goes where: a row for each event, a column for each channel.
private struct EventTable: View {
    var settings: AppSettings
    var telegramConnected: Bool

    private static let column: CGFloat = 64

    var body: some View {
        SettingsGroup {
            line {
                Text(L("Event")).frame(maxWidth: .infinity, alignment: .leading)
                header(L("Mac"))
                header(L("Sound"))
                header("Telegram")
            }
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(Palette.text2)
            .padding(.vertical, 7)
            // The group lifts its first row by the width of a line, which this one does not draw.
            .padding(.top, 1)
            ForEach(NotificationTopic.allCases) { topic in
                line {
                    Text(topic.label)
                        .font(.system(size: 12.5))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    channel(topic, L("Mac"), \.mac)
                    channel(topic, L("Sound"), \.sound).disabled(!settings.notifications.voiceOn)
                    channel(topic, "Telegram", \.telegram).disabled(!telegramConnected)
                }
                .frame(minHeight: 28)
                .overlay(alignment: .top) { Rectangle().fill(Palette.separator).frame(height: 1) }
            }
        }
    }

    private func line<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 8) { content() }.padding(.horizontal, 12)
    }

    private func header(_ text: String) -> some View {
        Text(text).lineLimit(1).frame(width: Self.column)
    }

    private func channel(_ topic: NotificationTopic, _ name: String, _ path: WritableKeyPath<ChannelChoice, Bool>) -> some View {
        Toggle(name, isOn: Binding {
            settings.notifications.choice(topic)[keyPath: path]
        } set: {
            var choice = settings.notifications.choice(topic)
            choice[keyPath: path] = $0
            settings.notifications.channels[topic] = choice
        })
        .toggleStyle(.switch)
        .controlSize(.mini)
        .labelsHidden()
        .frame(width: Self.column)
        .accessibilityLabel("\(topic.label), \(name)")
    }
}

private struct QuietRow: View {
    @Bindable var model: AppModel

    var body: some View {
        let now = Date()
        if model.quiet.isOn(now: now), let until = model.quiet.until {
            SettingsRow(title: L("Do not disturb")) {
                Text(until.timeIntervalSince(now) > QuietMode.indefinitely / 2 ? L("on") : L("on until %@", WorkFormat.time(until)))
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(Palette.waiting)
                Button(L("Turn off")) { model.stopQuiet() }.buttonStyle(PlainActionStyle(height: 22))
            }
        } else {
            SettingsRow(title: L("Do not disturb")) {
                Button(L("For an hour")) { model.startQuiet(for: 3600) }.buttonStyle(PlainActionStyle(height: 22))
                Button(L("For 4 hours")) { model.startQuiet(for: 4 * 3600) }.buttonStyle(PlainActionStyle(height: 22))
                Button(L("Until turned off")) { model.startQuiet(for: QuietMode.indefinitely) }.buttonStyle(PlainActionStyle(height: 22))
            }
        }
    }
}

private struct VoiceRow: View {
    @Bindable var model: AppModel

    private var settings: AppSettings { model.settings }

    var body: some View {
        SettingsRow(title: L("Walrus voice"), detail: L("Volume %@", WorkFormat.percent(settings.notifications.volume * 100))) {
            Slider(
                value: Binding { settings.notifications.volume } set: { settings.notifications.volume = $0 },
                in: 0...1,
                onEditingChanged: { editing in
                    if !editing { model.notifications.playSample() }
                }
            )
            .controlSize(.mini)
            .frame(width: 110)
            .disabled(!settings.notifications.voiceOn)
            .accessibilityLabel(L("Volume"))
            Toggle(L("Walrus voice"), isOn: Binding { settings.notifications.voiceOn } set: { settings.notifications.voiceOn = $0 })
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
        }
    }
}

private struct TelegramGroup: View {
    @Bindable var model: AppModel
    @State private var token = ""
    @State private var chat = ""
    @State private var problem: TelegramProblem?

    private var hub: NotificationHub { model.notifications }
    private var settings: AppSettings { model.settings }
    private var connected: Bool { !settings.notifications.telegramChat.isEmpty }

    var body: some View {
        SettingsGroup(title: "Telegram", footer: L("Notifications and Telegram carry only the project and the event, no commands or code. Telegram only informs: requests are not answered from it.")) {
            if connected {
                connectedRows
            } else if hub.telegramFormOpen {
                formRows
            } else {
                SettingsRow(title: L("Bot")) {
                    Text(L("no bot connected")).font(.system(size: 12)).foregroundStyle(Palette.text3)
                    Button(L("Connect a bot")) { hub.telegramFormOpen = true }.buttonStyle(PlainActionStyle(height: 22))
                }
            }
        }
    }

    @ViewBuilder private var connectedRows: some View {
        SettingsRow(title: L("Bot"), warning: resultWarning, warningIsProblem: hub.telegramResult?.problem != nil) {
            Text(L("bot connected")).font(.system(size: 12)).foregroundStyle(Palette.done)
            Button(L("Test message")) { Task { await hub.sendTelegramTest() } }
                .buttonStyle(PlainActionStyle(height: 22))
                .disabled(hub.telegramBusy)
            Button(L("Disconnect")) { hub.disconnectTelegram() }.buttonStyle(PlainActionStyle(height: 22))
        }
        SettingsRow(title: L("Send during Do not disturb"), detail: L("Do not disturb turns off the Mac and the sounds. Messages keep coming here unless you turn them off.")) {
            Toggle(L("Send during Do not disturb"), isOn: Binding { settings.notifications.telegramDuringQuiet } set: { settings.notifications.telegramDuringQuiet = $0 })
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
        }
    }

    /// Only the last test or failure is worth showing. A message that simply went needs no words.
    private var resultWarning: String {
        guard let result = hub.telegramResult else { return "" }
        if let problem = result.problem { return "\(WorkFormat.time(result.at)) · \(Self.words(problem))" }
        return result.wasTest ? L("%@ · Test message sent", WorkFormat.time(result.at)) : ""
    }

    @ViewBuilder private var formRows: some View {
        SettingsRow(title: L("Bot token"), detail: L("Create a bot with @BotFather in Telegram and paste its token. It is kept in the Keychain.")) {
            SecureField(L("Bot token"), text: $token).labelsHidden().textFieldStyle(.roundedBorder).controlSize(.small).frame(width: 190)
        }
        SettingsRow(title: L("Recipient"), detail: L("A chat number or an @channel name. Write to your bot first, otherwise it cannot write to you. @userinfobot tells you your number.")) {
            TextField(L("Recipient"), text: $chat).labelsHidden().textFieldStyle(.roundedBorder).controlSize(.small).frame(width: 190)
        }
        SettingsRow(title: "", warning: problem.map(Self.words) ?? "") {
            Button(L("Cancel")) {
                problem = nil
                token = ""
                hub.telegramFormOpen = false
            }
            .buttonStyle(PlainActionStyle(height: 22))
            Button(hub.telegramBusy ? L("Sending…") : L("Send a test message and connect")) {
                Task {
                    problem = await hub.connectTelegram(token: token, chat: chat)
                    if problem == nil { token = "" }
                }
            }
            .buttonStyle(PlainActionStyle(primary: true, height: 22))
            .disabled(hub.telegramBusy || token.isEmpty || chat.isEmpty)
        }
    }

    static func words(_ problem: TelegramProblem) -> String {
        switch problem {
        case .noConnection: return L("No connection to Telegram, so the message did not go. Boris and Claude work as usual.")
        case .badToken: return L("Telegram did not accept the token. Check it with @BotFather.")
        case .badRecipient: return L("Telegram did not find this recipient. Check the chat number.")
        case .botCannotWrite: return L("The bot cannot write to you. Open it in Telegram and press Start.")
        case .tooOften: return L("Telegram asks to write less often, so some messages did not go.")
        case .other: return L("The message did not go: Telegram answered with an error.")
        }
    }
}
