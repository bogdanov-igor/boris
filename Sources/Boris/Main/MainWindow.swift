import AppKit
import BorisCore
import BorisData
import SwiftUI

enum MainPhrases {
    static func sessionsAtWork(_ count: Int) -> String {
        count == 1 ? L("%lld session at work", count) : L("%lld sessions at work", count)
    }
}

@MainActor
final class MainWindowController: NSObject, NSWindowDelegate {
    private let model: AppModel
    private let connect: ConnectFlow
    private var window: NSWindow?
    var onOpenSettings: ((SettingsSection) -> Void)?

    /// Every page fits from this size up, in both modes and languages: checked by laying them out at each width.
    static let minimum = NSSize(width: 900, height: 600)

    init(model: AppModel, connect: ConnectFlow) {
        self.model = model
        self.connect = connect
    }

    func show() {
        if window == nil {
            let host = WindowFit.host(MainWindowView(model: model, connect: connect, openSettings: { [weak self] section in
                self?.onOpenSettings?(section)
            }))
            let created = WindowFit.window(host, title: "Boris", size: NSSize(width: 1200, height: 800), minimum: Self.minimum)
            created.delegate = self
            model.capture.watch(created, as: .main)
            created.setFrameAutosaveName("main")
            if !created.setFrameUsingName("main") { created.center() }
            WindowFit.keepOnScreen(created, minimum: Self.minimum)
            window = created
        }
        if window?.isVisible != true {
            SpeedLog.began(.openMainWindow)
            AppLog.note(.windowOpened, .word(.mainWindow))
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        model.setLookingClosely(true, from: .mainWindow)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        // Back from another window: what stalls now happens on the page shown here.
        SpeedLog.appeared(model.page == .projects ? model.projectsRoute.speedPlace : model.page.speedPlace)
        model.acknowledgeAlarm()
    }

    func windowWillClose(_ notification: Notification) {
        AppLog.note(.windowClosed, .word(.mainWindow))
        model.setLookingClosely(false, from: .mainWindow)
        // A window hidden from captures can never come back to them, so the next time a new one is made.
        if let closing = window, model.capture.wasHidden(closing) {
            closing.setFrameAutosaveName("")
            window = nil
        }
    }
}

struct MainWindowView: View {
    @Bindable var model: AppModel
    var connect: ConnectFlow
    var openSettings: (SettingsSection) -> Void

    var body: some View {
        HStack(spacing: 0) {
            Sidebar(model: model, openSettings: openSettings)
            Rectangle().fill(Palette.separator).frame(width: 1)
            ZStack(alignment: .bottomTrailing) {
                PageContent(model: model, connect: connect, openSettings: openSettings)
                VStack(alignment: .trailing, spacing: 12) {
                    if model.offerConnecting, connect.stage == .closed {
                        ConnectOffer(model: model, connect: connect)
                    }
                    if model.showIconNotice {
                        IconNotice(model: model, openSettings: openSettings)
                    }
                }
                .padding(20)
                ConnectSheet(model: model, connect: connect)
            }
        }
        .overlay(alignment: .bottomLeading) {
            WalrusLineOverlay(stage: model.walrus).padding(EdgeInsets(top: 0, leading: 218, bottom: 110, trailing: 0))
        }
        // A text whose values stay the same would otherwise keep the old language while the window is open.
        .id(model.settings.language)
        .background(Palette.window)
        .foregroundStyle(Palette.text1)
        .ignoresSafeArea()
    }
}

private struct Sidebar: View {
    @Bindable var model: AppModel
    var openSettings: (SettingsSection) -> Void

    private var mode: Binding<DisplayMode> {
        Binding { model.settings.displayMode } set: { model.setDisplayMode($0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            WindowDragArea().frame(height: 38)
            ForEach(AppPage.allCases.filter { $0.isShown(in: model.settings.displayMode) }) { page in
                item(page.title, selected: model.page == page, badge: page == .requests ? model.requestCount : 0) {
                    model.choose(page)
                }
            }
            item(L("Settings"), selected: false, badge: 0) { openSettings(.general) }
            Spacer(minLength: 8)
            SidebarWalrus(model: model, openAbout: { openSettings(.about) })
                .padding(.bottom, 10)
            ChoiceBar(options: [(DisplayMode.simple, L("Simple")), (DisplayMode.technical, L("Technical"))], selection: mode, label: L("View"), stretches: true)
        }
        .padding(EdgeInsets(top: 10, leading: 10, bottom: 12, trailing: 10))
        .frame(width: 210)
        .background(Palette.side)
    }

    private func item(_ title: String, selected: Bool, badge: Int, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 13, weight: selected ? .medium : .regular))
                    .frame(maxWidth: .infinity, alignment: .leading)
                if badge > 0 {
                    Text(verbatim: "\(badge)")
                        .font(.system(size: 11, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .frame(minWidth: 18, minHeight: 18)
                        .background(Capsule().fill(Palette.waiting))
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: DesignMetrics.radiusMedium).fill(selected ? Palette.fill2 : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct PageContent: View {
    @Bindable var model: AppModel
    var connect: ConnectFlow
    var openSettings: (SettingsSection) -> Void

    private var subtitle: String {
        if model.page == .activity { return L("Actions of all sessions in one feed") }
        return model.page == .now ? WorkFormat.today(model.now) : ""
    }

    var body: some View {
        VStack(spacing: 0) {
            // The page of projects has a header of its own, with the way back and its filters.
            if model.page != .projects {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    // The words of the header are part of what the window is moved by, as in a title bar.
                    Text(model.page.title).font(.system(size: 18, weight: .semibold)).allowsHitTesting(false)
                    Text(subtitle).font(.system(size: 12)).foregroundStyle(Palette.text2).lineLimit(1).allowsHitTesting(false)
                    if model.page == .walrus { WalrusPageTabs(model: model) }
                    if model.page == .requests { RequestsHeader(model: model) } else { Spacer(minLength: 0) }
                    if model.page == .walrus { WalrusImportButton(model: model) }
                    if model.page == .losses { LossPeriodBar(store: model.losses) }
                    if model.page == .spend {
                        SpendHeaderControls(usage: model.usage)
                            .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 5 }
                    }
                }
                .padding(.horizontal, 24)
                .frame(height: 52)
                .background(WindowDragArea())
                Rectangle().fill(Palette.separator).frame(height: 1)
            }
            ConnectionNotices(model: model, connect: connect)
            SourcesOffNotice(model: model, openSettings: openSettings)
            page.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder private var page: some View {
        switch model.page {
        case .now: NowPage(model: model).speedPlace(.now)
        case .projects: ProjectsPage(model: model)
        case .spend: SpendPage(model: model).speedPlace(.spend)
        case .requests: RequestsPage(model: model).speedPlace(.requests)
        case .activity: ActivityPage(model: model).speedPlace(.activity)
        case .losses: LossesPage(model: model).speedPlace(.losses)
        case .walrus: WalrusPage(model: model).speedPlace(.walrus)
        }
    }
}

/// What the person should know about the connection, above every page.
struct ConnectionNotices: View {
    @Bindable var model: AppModel
    var connect: ConnectFlow

    /// One banner for each thing to say. Files that cannot be read always come with a changed format, and the two would say the same words.
    /// The pages of current work are themselves the message about a missing folder, with the way out in the middle of them.
    static func shown(_ problems: [ConnectionStatus.Problem], page: AppPage) -> [ConnectionStatus.Problem] {
        problems.filter { problem in
            switch problem {
            case .filesUnreadable: return false
            case .claudeFolderMissing: return page != .now && page != .projects
            default: return true
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Self.shown(model.connectionStatus.problems, page: model.page), id: \.self) { problem in
                notice(problem)
            }
            UpdateNotice(updates: model.updates)
        }
    }

    @ViewBuilder private func notice(_ problem: ConnectionStatus.Problem) -> some View {
        switch problem {
        case .claudeFolderMissing:
            NoticeBanner(kind: .failed, tone: .problem, title: L("Cannot find Claude's folder"), text: FolderMissing.explanation(model)) {
                CopyDiagnosticsButton(model: model)
                Button(L("Choose folder…")) { FolderMissing.choose(model) }.buttonStyle(PlainActionStyle())
            }
        case .filesUnreadable, .formatChanged:
            NoticeBanner(kind: .doneWithErrors, title: L("Claude changed its data format"), text: L("Some data may not show. Copy the diagnostics so that Boris can be updated.")) {
                CopyDiagnosticsButton(model: model)
            }
        case .settingsUnreadable:
            NoticeBanner(kind: .failed, tone: .problem, title: L("Claude's settings file looks damaged"), text: L("Boris will not write to a file it cannot read reliably. Everything else keeps working.")) {
                EmptyView()
            }
        case .hooksDamaged:
            NoticeBanner(kind: .failed, tone: .problem, title: L("Answers from Boris are not working"), text: L("The hooks in Claude's settings were removed or changed. Data keeps updating.")) {
                Button(L("Repair")) { connect.repair(model, asker: .repairInMainWindow) }.buttonStyle(PlainActionStyle())
            }
        case .hooksSilent:
            NoticeBanner(kind: .unknown, title: L("No events from the hooks"), text: L("The hooks are connected and Claude is working, but no events are coming. Start a new Claude session, and if that does not help, copy the diagnostics.")) {
                CopyDiagnosticsButton(model: model)
            }
        case .hooksDisabledInSettings:
            NoticeBanner(kind: .stopped, title: L("Hooks are turned off in Claude's settings"), text: L("No instant updates or answers from Boris while `disableAllHooks` is on. Everything else works.")) {
                EmptyView()
            }
        case .hooksDisabledByPolicy:
            NoticeBanner(kind: .stopped, title: L("Hooks are forbidden by your company's policy"), text: L("No instant updates or answers from Boris. Everything else works.")) {
                EmptyView()
            }
        }
    }
}
