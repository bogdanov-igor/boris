import AppKit
import BorisCore
import BorisData
import ServiceManagement
import SwiftUI

@MainActor
final class SettingsWindowController {
    private let model: AppModel
    private let connect: ConnectFlow
    private let actions: SettingsActions
    private var window: NSWindow?
    private var closing: NSObjectProtocol?

    init(model: AppModel, connect: ConnectFlow, actions: SettingsActions) {
        self.model = model
        self.connect = connect
        self.actions = actions
    }

    func show(_ section: SettingsSection) {
        model.settingsSection = section
        if window == nil {
            let host = WindowFit.host(SettingsView(model: model, connect: connect, actions: actions))
            let created = NSWindow(contentViewController: host)
            created.title = L("Settings")
            created.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            created.titlebarAppearsTransparent = true
            created.titleVisibility = .hidden
            created.isReleasedWhenClosed = false
            created.setContentSize(NSSize(width: 760, height: 720))
            created.minSize = NSSize(width: 680, height: 520)
            created.center()
            if let visible = (created.screen ?? NSScreen.main)?.visibleFrame {
                created.setFrame(WindowFit.fitted(created.frame, in: visible), display: false)
            }
            closing = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: created, queue: .main) { _ in
                AppLog.note(.windowClosed, .word(.settingsWindow))
            }
            window = created
        }
        if window?.isVisible != true { AppLog.note(.windowOpened, .word(.settingsWindow)) }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

/// What the settings ask the rest of the app to do.
@MainActor
final class SettingsActions {
    var applyHotKey: () -> Void = {}
    var isAutostartAvailable: () -> Bool = { false }
    var autostartState: () -> AutostartState = { .off }
    /// Returns false when macOS refused.
    var setAutostart: (Bool) -> Bool = { _ in true }
    var openLoginItems: () -> Void = {}
}

struct SettingsView: View {
    @Bindable var model: AppModel
    var connect: ConnectFlow
    var actions: SettingsActions
    /// Starts on the text of a license, for a snapshot.
    var openLicense: AboutSection.LicenseText?

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Color.clear.frame(height: 34)
                ForEach(SettingsSection.allCases) { section in
                    Button {
                        model.settingsSection = section
                    } label: {
                        Text(section.title)
                            .font(.system(size: 13, weight: model.settingsSection == section ? .medium : .regular))
                            .padding(.horizontal, 8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .frame(height: 28)
                            .background(RoundedRectangle(cornerRadius: DesignMetrics.radiusMedium).fill(model.settingsSection == section ? Palette.fill2 : .clear))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(model.settingsSection == section ? .isSelected : [])
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .frame(width: 190)
            .background(Palette.side)
            Rectangle().fill(Palette.separator).frame(width: 1)
            content.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .overlay { ConnectSheet(model: model, connect: connect, place: .settings) }
        // A text whose values stay the same would otherwise keep the old language while the window is open.
        .id(model.settings.language)
        .background(Palette.window)
        .foregroundStyle(Palette.text1)
        .ignoresSafeArea()
    }

    @ViewBuilder private var content: some View {
        switch model.settingsSection {
        case .general: page { GeneralSettings(model: model, actions: actions) }
        case .connections: page { ConnectionSettings(model: model, connect: connect) }
        case .log: LogSection(model: model)
        case .about: AboutSection(model: model, license: openLicense)
        case .sources: page { SourcesSettings(model: model) }
        case .surfaces: page { SurfacesSettings(model: model) }
        case .notifications: page { NotificationSettings(model: model) }
        }
    }

    private func page<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(model.settingsSection.title).font(.system(size: 17, weight: .bold))
                content()
            }
            .padding(EdgeInsets(top: 34, leading: 22, bottom: 18, trailing: 22))
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// A rounded block of rows, as in System Settings.
struct SettingsGroup<Content: View>: View {
    var title = ""
    var footer = ""
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if !title.isEmpty {
                Text(title).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Palette.text2).padding(.leading, 4)
            }
            // Each row draws a line above itself, and the first one is lifted out of sight.
            VStack(alignment: .leading, spacing: 0) { content() }
                .padding(.top, -1)
                .background(Palette.fill1)
                .clipShape(RoundedRectangle(cornerRadius: DesignMetrics.radiusLarge))
            if !footer.isEmpty {
                Text(footer).font(.system(size: 11)).foregroundStyle(Palette.text3).padding(.horizontal, 4).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct SettingsRow<Trailing: View>: View {
    var title: String
    var detail = ""
    var warning = ""
    var warningIsProblem = true
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(title).font(.system(size: 12.5))
                    if !detail.isEmpty {
                        Text(detail).font(.system(size: 11)).lineSpacing(2).foregroundStyle(Palette.text3).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 8)
                trailing()
            }
            .frame(minHeight: 22)
            if !warning.isEmpty {
                Text(warning)
                    .font(.system(size: 11.5))
                    .lineSpacing(2)
                    .foregroundStyle(warningIsProblem ? Palette.redText : Palette.text2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .overlay(alignment: .top) { Rectangle().fill(Palette.separator).frame(height: 1) }
    }
}

private struct GeneralSettings: View {
    @Bindable var model: AppModel
    var actions: SettingsActions

    private var settings: AppSettings { model.settings }

    private var autostartWarning: String {
        if actions.autostartState() == .needsApproval { return L("Boris is turned off in System Settings, under Login Items. Only you can turn it on there.") }
        return autostartRefused ? L("macOS did not allow this. Try again, or check Login Items in System Settings.") : ""
    }

    @State private var autostartRefused = false

    private var autostart: Binding<Bool> {
        Binding { actions.autostartState() == .on } set: { autostartRefused = !actions.setAutostart($0) }
    }

    private var keepAwake: Binding<Bool> {
        Binding { settings.keepAwake } set: {
            settings.keepAwake = $0
            // The next look at the work may be a minute away, and the switch should mean something now.
            model.refreshPresence()
        }
    }

    private var mode: Binding<DisplayMode> { Binding { settings.displayMode } set: { model.setDisplayMode($0) } }
    private var language: Binding<AppLanguage> { Binding { settings.language } set: { settings.language = $0 } }
    private var theme: Binding<ThemeMode> { Binding { settings.theme } set: { settings.theme = $0 } }

    var body: some View {
        SettingsGroup {
            SettingsRow(title: L("View"), detail: L("Also switchable from the main window.")) {
                ChoiceBar(options: [(DisplayMode.simple, L("Simple")), (DisplayMode.technical, L("Technical"))], selection: mode, label: L("View"))
            }
            SettingsRow(title: L("Language")) {
                ChoiceBar(options: AppLanguage.allCases.map { ($0, $0.nativeName) }, selection: language, label: L("Language"))
            }
            SettingsRow(title: L("Appearance")) {
                ChoiceBar(options: [(ThemeMode.light, L("Light")), (ThemeMode.dark, L("Dark")), (ThemeMode.system, L("As in the system"))], selection: theme, label: L("Appearance"))
            }
        }
        SettingsGroup {
            SettingsRow(
                title: L("Open at login"),
                detail: actions.isAutostartAvailable() ? "" : L("Available in the installed app."),
                warning: autostartWarning
            ) {
                if actions.autostartState() == .needsApproval {
                    Button(L("Open System Settings")) { actions.openLoginItems() }.buttonStyle(PlainActionStyle(height: 22))
                }
                Toggle("", isOn: autostart).toggleStyle(.switch).controlSize(.mini).labelsHidden().disabled(!actions.isAutostartAvailable())
            }
            SettingsRow(
                title: L("Mini window hotkey"),
                warning: model.hotKeyTaken ? L("%@ is already taken by another app. Choose another combination, or the key may not work.", settings.hotKey.label) : ""
            ) {
                HotKeyField(model: model, actions: actions)
            }
            SettingsRow(
                title: L("Keep the Mac awake while work is running"),
                detail: L("With the lid closed the Mac sleeps anyway, unless it is on power with an external display.")
            ) {
                Toggle("", isOn: keepAwake).toggleStyle(.switch).controlSize(.mini).labelsHidden()
            }
        }
        UpdateSettings(updates: model.updates)
    }
}

/// Shows the combination, and takes the next one pressed after a click.
private struct HotKeyField: View {
    @Bindable var model: AppModel
    var actions: SettingsActions
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        Button {
            recording ? stop() : start()
        } label: {
            Text(recording ? L("Press keys…") : model.settings.hotKey.label)
                .font(.system(size: 12, design: .monospaced))
                .padding(.horizontal, 10)
                .frame(height: 22)
                .background(RoundedRectangle(cornerRadius: DesignMetrics.radiusMedium).fill(Palette.button))
                .overlay(
                    RoundedRectangle(cornerRadius: DesignMetrics.radiusMedium)
                        .strokeBorder(model.hotKeyTaken ? Palette.red : Palette.buttonBorder, lineWidth: model.hotKeyTaken ? 1.5 : 0.5)
                )
        }
        .buttonStyle(.plain)
        .onDisappear(perform: stop)
    }

    private func start() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 {
                stop()
                return nil
            }
            guard let combo = HotKeyCombo(event: event) else { return nil }
            model.settings.hotKey = combo
            actions.applyHotKey()
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

private struct ConnectionSettings: View {
    @Bindable var model: AppModel
    var connect: ConnectFlow
    @State private var problem: String?

    private var status: ConnectionStatus { model.connectionStatus }

    var body: some View {
        SettingsGroup(title: L("Answers to requests (hooks)")) {
            hooksRow
            RequestSettingsRows(model: model)
        }
        if let problem {
            Text(problem).font(.system(size: 11.5)).foregroundStyle(Palette.redText)
        }
        UsageRefreshSettings(model: model)
        SettingsGroup(title: L("Diagnostics")) {
            folderRow
            checkRow(L("File reading"), ok: !status.problems.contains(.filesUnreadable), text: status.problems.contains(.filesUnreadable) ? L("cannot read") : WorkFormat.ago(model.now.timeIntervalSince(status.lastRead)))
            checkRow(L("Data format"), ok: !status.problems.contains(.formatChanged), text: status.problems.contains(.formatChanged) ? L("changed") : L("in order"), warning: status.problems.contains(.formatChanged) ? L("Some data may not show. Copy the diagnostics so that Boris can be updated.") : "")
            checkRow(L("Hooks"), ok: hooksOK, text: hooksWord, neutral: status.hooks == .notConnected)
            checkRow(
                L("Last event"),
                ok: !status.hooksSilent,
                text: status.lastHookEvent.map { WorkFormat.ago(model.now.timeIntervalSince($0)) } ?? L("none yet"),
                neutral: status.lastHookEvent == nil && !status.hooksSilent,
                warning: status.hooksSilent ? L("The hooks are connected and Claude is working, but no events are coming. Start a new Claude session, and if that does not help, copy the diagnostics.") : ""
            )
            checkRow(L("Limits data"), ok: true, text: limitsWord, neutral: status.limits == .noData)
            SettingsRow(title: "") {
                if status.hooks == .damaged {
                    Button(L("Repair")) { connect.repair(model, in: .settings, asker: .repairInDiagnostics) }.buttonStyle(PlainActionStyle(height: 22))
                }
                CopyDiagnosticsButton(model: model, height: 22)
            }
        }
    }

    /// A missing folder is the one problem here whose way out is a choice of the person's.
    private var folderRow: some View {
        SettingsRow(title: L("Claude's folder"), warning: status.claudeFolderFound ? "" : FolderMissing.explanation(model)) {
            Text(status.claudeFolderFound ? L("in order") : L("not found"))
                .font(.system(size: 12))
                .foregroundStyle(status.claudeFolderFound ? Palette.text2 : Palette.redText)
            StatusGlyph(kind: status.claudeFolderFound ? .done : .failed, size: 14)
            if !status.claudeFolderFound {
                Button(L("Choose folder…")) { FolderMissing.choose(model) }.buttonStyle(PlainActionStyle(height: 22))
            }
        }
    }

    private var hooksOK: Bool {
        status.hooks == .connected || status.hooks == .notConnected
    }

    private var hooksWord: String {
        switch status.hooks {
        case .notConnected: return L("not connected")
        case .connected: return L("connected")
        case .damaged: return L("damaged")
        case .settingsUnreadable: return L("file damaged")
        case .disabledInSettings: return L("turned off")
        case .disabledByPolicy: return L("forbidden")
        }
    }

    /// Their age, also when they are fresh: that is what the person came here to see.
    private var limitsWord: String {
        switch status.limits {
        case .noData: return L("no data")
        case .fresh: return model.world.usage?.fetchedAt.map { WorkFormat.ago(model.now.timeIntervalSince($0)) } ?? L("fresh")
        case .stale(let age): return WorkFormat.ago(age)
        }
    }

    private func checkRow(_ title: String, ok: Bool, text: String, neutral: Bool = false, warning: String = "") -> some View {
        SettingsRow(title: title, warning: warning) {
            Text(text).font(.system(size: 12).monospacedDigit()).foregroundStyle(ok ? Palette.text2 : Palette.redText)
            StatusGlyph(kind: neutral ? .idle : (ok ? .done : .failed), size: 14)
        }
    }

    @ViewBuilder private var hooksRow: some View {
        switch status.hooks {
        case .notConnected:
            SettingsRow(title: L("Hooks"), detail: L("Boris sees everything without them. With them, events arrive instantly and you can answer from here.")) {
                Button(L("Connect answers")) { connect.begin(model, in: .settings) }.buttonStyle(PlainActionStyle(primary: true, height: 22))
            }
        case .connected:
            SettingsRow(title: L("Hooks")) {
                // In the narrowest window the mark says it alone, and the buttons keep their words.
                ViewThatFits(in: .horizontal) {
                    connectedControls(saying: true)
                    connectedControls(saying: false)
                }
            }
        case .damaged:
            SettingsRow(title: L("Hooks"), warning: L("Data keeps updating, but you cannot answer from Boris right now.")) {
                Text(L("damaged")).font(.system(size: 12)).foregroundStyle(Palette.redText)
                StatusGlyph(kind: .failed, size: 14)
                Button(L("Repair")) { connect.repair(model, in: .settings, asker: .repairInConnections) }.buttonStyle(PlainActionStyle(primary: true, height: 22))
            }
        case .settingsUnreadable:
            SettingsRow(title: L("Hooks"), warning: L("Boris will not write to a file it cannot read reliably. Everything else keeps working.")) {
                StatusGlyph(kind: .failed, size: 14)
            }
        case .disabledInSettings:
            SettingsRow(title: L("Hooks"), warning: L("No instant updates or answers from Boris while `disableAllHooks` is on. Everything else works."), warningIsProblem: false) {
                StatusGlyph(kind: .stopped, size: 14)
            }
        case .disabledByPolicy:
            SettingsRow(title: L("Hooks"), warning: L("No instant updates or answers from Boris. Everything else works."), warningIsProblem: false) {
                StatusGlyph(kind: .stopped, size: 14)
            }
        }
    }

    private func connectedControls(saying: Bool) -> some View {
        HStack(spacing: 10) {
            if saying { Text(L("connected")).font(.system(size: 12)).foregroundStyle(Palette.done).fixedSize() }
            StatusGlyph(kind: .done, size: 14)
            Button(L("Settings changes")) { connect.showEntries(model, in: .settings) }.buttonStyle(PlainActionStyle(height: 22)).fixedSize()
            Button(L("Disconnect")) { disconnect() }.buttonStyle(PlainActionStyle(height: 22)).fixedSize()
        }
    }

    private func disconnect() {
        do {
            try model.hooks.disconnect(asker: .disconnectInConnections)
            problem = nil
        } catch {
            problem = L("Could not write Claude's settings. Nothing has changed.")
        }
    }
}
