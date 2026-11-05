import BorisCore
import BorisData
import Observation
import SwiftUI

/// Connecting the hooks step by step: the exact changes first, then the wait for a first event.
@MainActor
@Observable
final class ConnectFlow {
    enum Stage: Equatable {
        case closed
        case preview(HookInstaller.Preview)
        case waiting(since: Date)
        case connected
        case failed(String)
    }

    var stage = Stage.closed

    func begin(_ model: AppModel) {
        do {
            stage = .preview(try model.hooks.preview())
        } catch {
            stage = .failed(L("Boris will not write to a file it cannot read reliably. Everything else keeps working."))
        }
    }

    func confirm(_ model: AppModel) {
        do {
            try model.hooks.connect()
            model.offerConnecting = false
            stage = .waiting(since: Date())
        } catch {
            stage = .failed(L("Could not write Claude's settings. Nothing has changed."))
        }
    }

    /// One button, with no questions: the person already agreed to these entries.
    func repair(_ model: AppModel) {
        do {
            try model.hooks.connect()
        } catch {
            stage = .failed(L("Could not write Claude's settings. Nothing has changed."))
        }
    }

    func close() {
        stage = .closed
    }
}

/// The optional offer on top of a Boris that already works.
struct ConnectOffer: View {
    @Bindable var model: AppModel
    var connect: ConnectFlow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                WalrusView(mood: .sleeping, outfit: model.outfit, size: 64, style: .simple)
                VStack(alignment: .leading, spacing: 4) {
                    Text(L("Connect answers to requests?")).font(.system(size: 14, weight: .bold))
                    Text(L("I can already see all the sessions. With answers connected, events arrive instantly and you can answer Claude's requests from here. For that I will change Claude's settings and show you exactly how."))
                        .font(.system(size: 12.5))
                        .lineSpacing(3)
                        .foregroundStyle(Palette.text2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(spacing: 8) {
                Text(L("You can come back to this in Connections")).font(.system(size: 11)).foregroundStyle(Palette.text3)
                Spacer(minLength: 0)
                Button(L("Not now")) { model.offerConnecting = false }.buttonStyle(PlainActionStyle(height: 26))
                Button(L("Show changes")) { connect.begin(model) }.buttonStyle(PlainActionStyle(primary: true, height: 26))
            }
        }
        .padding(EdgeInsets(top: 14, leading: 16, bottom: 14, trailing: 16))
        .frame(width: 420)
        .background(RoundedRectangle(cornerRadius: 12).fill(Palette.pop))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Palette.separator, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.3), radius: 20, y: 8)
    }
}

/// The icon did not fit in the menu bar.
struct IconNotice: View {
    @Bindable var model: AppModel
    var openSettings: (SettingsSection) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                WalrusView(mood: .hmm, outfit: model.outfit, size: 64, style: .simple)
                VStack(alignment: .leading, spacing: 4) {
                    Text(L("My icon went behind the notch")).font(.system(size: 14, weight: .bold))
                    Text(L("There was not enough room in the menu bar. For now, open me with %@. To bring the icon back, hold ⌘ and drag other icons out of the menu bar.", model.settings.hotKey.label))
                        .font(.system(size: 12.5))
                        .lineSpacing(3)
                        .foregroundStyle(Palette.text2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button(L("Change the key")) { openSettings(.general) }.buttonStyle(PlainActionStyle(height: 26))
                Button(L("Got it")) { model.dismissIconNotice() }.buttonStyle(PlainActionStyle(primary: true, height: 26))
            }
        }
        .padding(EdgeInsets(top: 14, leading: 16, bottom: 14, trailing: 16))
        .frame(width: 420)
        .background(RoundedRectangle(cornerRadius: 12).fill(Palette.pop))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Palette.separator, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.3), radius: 20, y: 8)
    }
}

/// The exact changes, the wait for the first event and the result.
struct ConnectSheet: View {
    @Bindable var model: AppModel
    var connect: ConnectFlow

    var body: some View {
        if connect.stage != .closed {
            ZStack(alignment: .top) {
                Color.black.opacity(0.28)
                VStack(alignment: .leading, spacing: 12) { content }
                    .padding(EdgeInsets(top: 18, leading: 20, bottom: 16, trailing: 20))
                    .frame(width: 520)
                    .background(UnevenRoundedRectangle(bottomLeadingRadius: 12, bottomTrailingRadius: 12).fill(Palette.pop))
                    .shadow(color: .black.opacity(0.35), radius: 20, y: 8)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onChange(of: model.hookState.lastEventAt) { _, event in
                if case .waiting(let since) = connect.stage, let event, event > since { connect.stage = .connected }
            }
        }
    }

    private func heading(_ mood: Mood, _ title: String, _ detail: String) -> some View {
        HStack(spacing: 12) {
            WalrusView(mood: mood, outfit: model.outfit, size: 48, style: .simple)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 14, weight: .bold))
                Text(detail).font(.system(size: 12.5)).foregroundStyle(Palette.text2).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func check(_ kind: StatusGlyph.Kind, _ text: String) -> some View {
        HStack(spacing: 8) {
            StatusGlyph(kind: kind, size: 14)
            Text(text).font(.system(size: 12.5))
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder private var content: some View {
        switch connect.stage {
        case .closed:
            EmptyView()
        case .preview(let preview):
            heading(.sleeping, L("What will change in Claude's settings"), L("Boris's hooks will be added. Everything else stays as it was."))
            VStack(alignment: .leading, spacing: 0) {
                Text(model.hooks.settingsFile.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                    .font(.system(size: 11, design: .monospaced))
                    .padding(EdgeInsets(top: 5, leading: 10, bottom: 5, trailing: 10))
                Rectangle().fill(Palette.separator).frame(height: 1)
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(preview.lines.enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.system(size: 11.5, design: .monospaced))
                                .foregroundStyle(line.hasPrefix("+") ? Palette.done : Palette.redText)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .padding(.horizontal, 10)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(line.hasPrefix("+") ? Palette.doneSoft : Palette.redSoft)
                        }
                    }
                }
                .frame(maxHeight: 320)
            }
            .background(RoundedRectangle(cornerRadius: DesignMetrics.radiusLarge).fill(Palette.window))
            .clipShape(RoundedRectangle(cornerRadius: DesignMetrics.radiusLarge))
            .overlay(RoundedRectangle(cornerRadius: DesignMetrics.radiusLarge).strokeBorder(Palette.separator))
            if preview.reformats {
                Text(L("Claude's settings file will also be laid out differently. What is in it stays the same."))
                    .font(.system(size: 11.5)).foregroundStyle(Palette.text2).fixedSize(horizontal: false, vertical: true)
            }
            Text(L("The old version of the file is kept next to it. You can disconnect in Connections, and the settings will go back to what they were."))
                .font(.system(size: 11.5)).foregroundStyle(Palette.text2).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button(L("Cancel")) { connect.close() }.buttonStyle(PlainActionStyle(height: 26))
                Button(L("Connect")) { connect.confirm(model) }.buttonStyle(PlainActionStyle(primary: true, height: 26))
            }
        case .waiting:
            heading(.alert, L("Waiting for the first event"), L("Do something in any Claude Code session."))
            VStack(spacing: 6) {
                check(.done, L("Settings written"))
                check(.running, L("First event from Claude"))
            }
            .padding(EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12))
            .background(RoundedRectangle(cornerRadius: DesignMetrics.radiusLarge).fill(Palette.fill1))
            HStack {
                Spacer(minLength: 0)
                Button(L("Close")) { connect.close() }.buttonStyle(PlainActionStyle(height: 26))
            }
        case .connected:
            heading(.happy, L("Answers are connected"), L("You can now answer requests in the notch, the mini window and on the Requests page."))
            VStack(spacing: 6) {
                check(.done, L("Settings written"))
                check(.done, L("First event from Claude"))
            }
            .padding(EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12))
            .background(RoundedRectangle(cornerRadius: DesignMetrics.radiusLarge).fill(Palette.fill1))
            HStack {
                Spacer(minLength: 0)
                Button(L("Done")) { connect.close() }.buttonStyle(PlainActionStyle(primary: true, height: 26))
            }
        case .failed(let message):
            heading(.broken, L("Could not connect"), message)
            HStack {
                Spacer(minLength: 0)
                Button(L("Close")) { connect.close() }.buttonStyle(PlainActionStyle(height: 26))
            }
        }
    }
}
