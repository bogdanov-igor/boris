import AppKit
import BorisCore
import BorisData
import SwiftUI

/// The part of «Connections» about remote machines: what is connected, why something is not, and the way to add one.
struct RemoteMachinesSettings: View {
    @Bindable var model: AppModel
    @State private var name = ""
    @State private var addProblem: String?

    /// The guide travels inside the installed app. A developer's build has none, and then there is no button.
    private static var guide: URL? { Bundle.main.url(forResource: "remote-ssh", withExtension: "md") }

    private var hub: RemoteHub { model.remote }

    var body: some View {
        SettingsGroup(
            title: L("Remote machines over SSH"),
            footer: L("Boris uses the ssh on this Mac with your own keys and settings, and stores no passwords. Session status, numbers of spend and requests reach this Mac. The text of conversations stays on the machine.")
        ) {
            ForEach(hub.rows) { row in
                RemoteMachineRows(hub: hub, row: row)
            }
            addRow
            if let guide = Self.guide {
                SettingsRow(title: L("First time?"), detail: L("The guide goes through it step by step, with what to do when something does not connect.")) {
                    Button(L("Open the guide")) { open(guide) }.buttonStyle(PlainActionStyle(height: 22))
                }
            }
        }
        if let host = hub.leftBehind {
            HStack(alignment: .top, spacing: 8) {
                Text(L("%@ could not be reached, so its hooks and helper stayed on it. They do nothing without Boris. The guide says how to take them off by hand.", host))
                    .font(.system(size: 11.5))
                    .foregroundStyle(Palette.text2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                Button(L("OK")) { hub.dismissLeftBehind() }.buttonStyle(PlainActionStyle(height: 22))
            }
        }
    }

    private var addRow: some View {
        SettingsRow(title: L("Add a machine"), detail: L("Its name in ~/.ssh/config, or user@address. Boris puts a small helper in ~/.boris on it."), warning: addProblem ?? "") {
            TextField("", text: $name, prompt: Text(verbatim: "build-server"))
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))
                .frame(width: 170)
                .onSubmit(add)
                .accessibilityLabel(L("Machine name"))
            Button(L("Add")) { add() }
                .buttonStyle(PlainActionStyle(height: 22))
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    /// Not every Mac has something set up for this kind of file, and TextEdit can always show it.
    private func open(_ guide: URL) {
        let reader = NSWorkspace.shared.urlForApplication(toOpen: guide) ?? URL(fileURLWithPath: "/System/Applications/TextEdit.app")
        NSWorkspace.shared.open([guide], withApplicationAt: reader, configuration: NSWorkspace.OpenConfiguration())
    }

    private func add() {
        switch hub.add(name) {
        case .added:
            name = ""
            addProblem = nil
        case .invalidName:
            addProblem = L("This does not look like a machine name. Use its name in ~/.ssh/config, or user@address.")
        case .alreadyThere:
            addProblem = L("This machine is already on the list.")
        }
    }
}

/// One machine: how the connection stands, and below it how its hooks stand.
private struct RemoteMachineRows: View {
    var hub: RemoteHub
    var row: RemoteHub.Row

    var body: some View {
        SettingsRow(title: row.machine.name, detail: RemoteWords.detail(row), warning: warning) {
            status
            if row.confirmingRemoval {
                Button(L("Remove")) { hub.remove(row.id) }.buttonStyle(PlainActionStyle(primary: true, height: 22))
                Button(L("Cancel")) { hub.askRemoval(row.id, false) }.buttonStyle(PlainActionStyle(height: 22))
            } else {
                if row.failure != nil {
                    Button(L("Check")) { hub.retry(row.id) }.buttonStyle(PlainActionStyle(height: 22))
                }
                Button(L("Remove…")) { hub.askRemoval(row.id, true) }.buttonStyle(PlainActionStyle(height: 22))
            }
        }
        if row.confirmingRemoval {
            SettingsRow(title: "", detail: L("Boris takes its hooks and helper off the machine if it can reach it. Claude and your work there stay as they are."), trailing: { EmptyView() })
        }
        if row.isUp { hooksRow }
        if let preview = row.preview { previewRow(preview) }
    }

    private var warning: String {
        switch row.problem {
        case .unreachable: return L("The machine did not answer. Nothing has changed on it.")
        case .settingsUnreadable: return L("Boris will not write to a settings file it cannot read reliably. Nothing has changed on the machine.")
        case .leftBehind, nil: return ""
        }
    }

    private var status: some View {
        HStack(spacing: 6) {
            Text(RemoteWords.state(row))
                .font(.system(size: 12))
                .foregroundStyle(row.isUp ? Palette.done : Palette.text2)
                .lineLimit(1)
                .fixedSize()
            StatusGlyph(kind: glyph, size: 14)
        }
    }

    private var glyph: StatusGlyph.Kind {
        switch row.state {
        case .up: return row.vitals?.socket == false ? .silent : .done
        case .connecting: return .running
        case .down, .stopped: return .unknown
        }
    }

    @ViewBuilder private var hooksRow: some View {
        switch row.hooks {
        case .installed where !row.hooksDamaged:
            SettingsRow(title: L("Live events and answers")) {
                Text(L("connected")).font(.system(size: 12)).foregroundStyle(Palette.done)
                StatusGlyph(kind: .done, size: 14)
                Button(L("Disconnect")) { hub.disconnectHooks(row.id) }.buttonStyle(PlainActionStyle(height: 22)).disabled(row.busy)
            }
        case .notInstalled where !row.hooksDamaged:
            SettingsRow(title: L("Live events and answers"), detail: L("Status and spend update without hooks. With them on that machine, events arrive instantly and you can answer from here.")) {
                Button(row.busy ? L("Asking…") : L("Connect answers")) { hub.askHooks(row.id) }.buttonStyle(PlainActionStyle(primary: true, height: 22)).disabled(row.busy || row.preview != nil)
            }
        case .notInstalled, .outdated, .installed:
            SettingsRow(title: L("Live events and answers"), warning: L("The hooks on that machine are gone or changed. Status and spend keep updating, but you cannot answer from Boris.")) {
                Text(L("damaged")).font(.system(size: 12)).foregroundStyle(Palette.redText)
                StatusGlyph(kind: .failed, size: 14)
                Button(L("Repair")) { hub.confirmHooks(row.id) }.buttonStyle(PlainActionStyle(primary: true, height: 22)).disabled(row.busy)
            }
        case .disabledInSettings:
            SettingsRow(title: L("Live events and answers"), warning: L("`disableAllHooks` is on in Claude's settings on that machine. Status and spend still update."), warningIsProblem: false) {
                StatusGlyph(kind: .stopped, size: 14)
            }
        case .disabledByPolicy:
            SettingsRow(title: L("Live events and answers"), warning: L("A company policy forbids hooks on that machine. Status and spend still update."), warningIsProblem: false) {
                StatusGlyph(kind: .stopped, size: 14)
            }
        case .unreadable:
            SettingsRow(title: L("Live events and answers"), warning: L("Boris will not write to a settings file it cannot read reliably. Status and spend still update.")) {
                StatusGlyph(kind: .failed, size: 14)
            }
        case nil:
            EmptyView()
        }
    }

    private func previewRow(_ preview: RemoteHookResult) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L("These lines change in ~/.claude/settings.json on %@. A copy of the file stays next to it.", row.machine.name))
                .font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)
            ScrollView {
                Text(verbatim: preview.lines.joined(separator: "\n"))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Palette.text2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .textSelection(.enabled)
            }
            .frame(maxHeight: 180)
            .background(RoundedRectangle(cornerRadius: DesignMetrics.radiusMedium).fill(Palette.fill2))
            if preview.reformats {
                Text(L("The layout of the file changes as well. What is in it stays the same."))
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.text3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button(L("Cancel")) { hub.cancelHooks(row.id) }.buttonStyle(PlainActionStyle(height: 24))
                Button(L("Add these lines")) { hub.confirmHooks(row.id) }.buttonStyle(PlainActionStyle(primary: true, height: 24)).disabled(row.busy)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .overlay(alignment: .top) { Rectangle().fill(Palette.separator).frame(height: 1) }
    }
}

/// The words for how a machine stands, with what to do about it.
enum RemoteWords {
    static func state(_ row: RemoteHub.Row) -> String {
        switch row.state {
        case .up: return L("connected")
        case .connecting: return L("connecting…")
        case .down, .stopped: return L("no connection")
        }
    }

    static func detail(_ row: RemoteHub.Row) -> String {
        if case .up = row.state {
            if row.vitals?.socket == false {
                return L("Live events and requests cannot get through, because the machine does not forward the socket. Status and spend update. The guide says how to turn this on.")
            }
            if row.vitals?.claudeFound == false { return L("Claude Code has not been used on this machine yet.") }
            return ""
        }
        guard let failure = row.failure else { return "" }
        return failureText(failure, machine: row.machine.name)
    }

    static func failureText(_ failure: RemoteFailure, machine: String) -> String {
        switch failure {
        case .noSSH:
            return L("There is no ssh program on this Mac.")
        case .refused:
            return L("The machine wants a password or a code, or refused your key. Boris cannot type anything into ssh, so it needs a key that works without a question.")
        case .hostKey:
            return L("This Mac does not know the machine yet, or its key changed. Connect once in Terminal: ssh %@", machine)
        case .unknownName:
            return L("No machine goes by this name. Check it in ~/.ssh/config.")
        case .unreachable:
            return L("The machine does not answer. It may be off, or behind a VPN. Boris keeps trying.")
        case .noPython:
            return L("python3 was not found on the machine, and the helper needs it.")
        case .dropped:
            return L("The connection dropped. Claude keeps working there, and Boris keeps trying.")
        case .helperBroken:
            return L("The helper on the machine did not answer as expected. Boris keeps trying.")
        case .other(let code):
            return L("ssh stopped with code %lld. Boris keeps trying.", Int(code))
        }
    }

    /// One live event in the words of the chosen mode. Nothing but names of tools is known about it, and that is on purpose.
    static func event(_ event: RemoteEvent, mode: DisplayMode) -> String {
        switch event.kind {
        case .started: return L("The session started")
        case .ended: return L("The session ended")
        case .turnEnded: return L("Finished the turn")
        case .failed: return L("Claude reported an error")
        case .answered: return L("You answered from here")
        case .agentStarted: return mode == .simple ? L("Called in a helper") : L("An agent started")
        case .agentStopped: return mode == .simple ? L("A helper finished") : L("An agent stopped")
        case .waiting(let tool):
            return WorkPhrases.waiting(tool.map { .permission(tool: $0) } ?? .input, mode: mode)
        case .tool(let tool):
            return WorkPhrases.step(StepBrief(kind: StepKind(tool: tool), tool: tool), mode: mode) ?? tool
        }
    }
}
