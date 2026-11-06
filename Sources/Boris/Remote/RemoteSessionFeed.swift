import BorisCore
import BorisData
import SwiftUI

/// What a session on a remote machine has been doing, as far as its events tell. Its log stays on the machine, so there are no words in here.
struct RemoteSessionFeed: View {
    @Bindable var model: AppModel
    var session: WorkSession

    private var mode: DisplayMode { model.settings.displayMode }

    private var host: String {
        if case .remote(let host) = session.environment { return host }
        return ""
    }

    private var events: [RemoteEvent] {
        // Read here so that the list changes with each event.
        _ = model.remote.eventVersion
        return model.remote.events(session: session.id).reversed()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(mode == .technical ? L("Events") : L("What’s going on"))
                .font(.system(size: mode == .technical ? 12.5 : 13, weight: .semibold))
                .padding(.horizontal, mode == .technical ? 16 : 0)
                .frame(height: mode == .technical ? 40 : 24, alignment: .leading)
            if mode == .technical { Rectangle().fill(Palette.separator).frame(height: 1) }
            Text(note)
                .font(.system(size: 11.5))
                .foregroundStyle(Palette.text2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, mode == .technical ? 16 : 0)
                .padding(.vertical, 8)
            if events.isEmpty {
                Text(L("No events yet"))
                    .font(.system(size: 12.5))
                    .foregroundStyle(Palette.text2)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(events) { line($0) }
                    }
                    .padding(.horizontal, mode == .technical ? 16 : 0)
                }
            }
        }
    }

    private var note: String {
        if session.state == .unreachable {
            return L("No connection to %@. Claude keeps working there, and the events will continue when the connection is back.", host)
        }
        if model.remote.hooksConnected(host: host) {
            return L("The log of this session stays on %@. Events, requests and numbers of spend reach this Mac.", host)
        }
        return L("The log of this session stays on %@. Live events need hooks on that machine: Settings, Connections.", host)
    }

    private func line(_ event: RemoteEvent) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(WorkFormat.time(event.at))
                .font(.system(size: 11.5).monospacedDigit())
                .foregroundStyle(Palette.text3)
            Text(RemoteWords.event(event, mode: mode))
                .font(.system(size: 12.5))
                .lineLimit(2)
            if mode == .technical, let agent = event.agent {
                Text(String(agent.prefix(8)))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Palette.text3)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 3)
    }
}
