import AppKit
import BorisCore
import SwiftUI

/// Sizes from the design that the window has to know before SwiftUI lays anything out.
enum SurfaceMetrics {
    static let notchText: CGFloat = 12
    static let pillText: CGFloat = 12.5
    static let pillWalrus: CGFloat = 26
    static let pillSpacing: CGFloat = 8
    static let notchWalrus: CGFloat = 28
    static let stripText: CGFloat = 12
    static let stripLeading: CGFloat = 5
    static let stripSpacing: CGFloat = 5
    static let stripTrailing: CGFloat = 11
    /// His picture leaves room for tall hats, so it is drawn larger than the place it takes in the row.
    static let walrusOverdraw: CGFloat = 1.3

    static func textWidth(_ line: SurfaceLine, size: CGFloat) -> CGFloat {
        var width: CGFloat = 0
        if !line.main.isEmpty {
            width += measure(line.main, NSFont.monospacedDigitSystemFont(ofSize: size, weight: .regular))
        }
        if !line.waiting.isEmpty {
            let text = line.main.isEmpty ? line.waiting : "· \(line.waiting)"
            width += measure(text, NSFont.monospacedDigitSystemFont(ofSize: size, weight: .semibold))
        }
        return width + (line.main.isEmpty || line.waiting.isEmpty ? 0 : pillSpacing)
    }

    /// He is drawn larger than his place, and the window ends at the edge of the menu bar, so his hat decides how large he can be.
    static func stripWalrus(height: CGFloat) -> CGFloat {
        min((height / walrusOverdraw).rounded(.down), pillWalrus)
    }

    static func stripWidth(_ line: SurfaceLine, height: CGFloat) -> CGFloat {
        let walrus = stripWalrus(height: height)
        let text = textWidth(line, size: stripText)
        return text > 0 ? stripLeading + walrus + stripSpacing + text + stripTrailing : stripLeading + walrus + stripLeading
    }

    private static func measure(_ text: String, _ font: NSFont) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: font]).width) + 1
    }
}

/// The notch, or the panel on a screen without one: the same functions in two shapes.
struct SurfaceView: View {
    @Bindable var model: AppModel
    var stage: SurfaceStage
    var speak: () -> Void
    var openMain: () -> Void
    var openSettings: () -> Void
    var contentHeight: (CGFloat) -> Void

    var body: some View {
        Group {
            if !stage.hasNotch {
                panel
            } else if stage.isOpen {
                open
            } else {
                closedNotch
            }
        }
        // A row whose values stay the same would otherwise keep the old language while the surface is open.
        .id(model.settings.language)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .foregroundStyle(Palette.text1)
        .contextMenu {
            Button(L("Open Boris"), action: openMain)
            Button(L("Settings…"), action: openSettings)
            Divider()
            Button(L("Quit")) { NSApp.terminate(nil) }
        }
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var mode: DisplayMode { model.settings.displayMode }

    private func walrus(_ size: CGFloat) -> some View {
        WalrusView(mood: model.mood, outfit: model.outfit, size: size * SurfaceMetrics.walrusOverdraw, style: .simple, stage: model.walrus, onPoke: speak)
            .frame(width: size, height: size)
    }

    // MARK: - Closed

    private var closedNotch: some View {
        let wings = stage.closedNotch
        return HStack(spacing: 0) {
            walrus(SurfaceMetrics.notchWalrus)
                .padding(.leading, 8)
                .frame(width: wings.left, alignment: .leading)
            Color.clear.frame(width: wings.cutout)
            lineText(stage.line, size: SurfaceMetrics.notchText, waitingWeight: .regular)
                .padding(.trailing, 14)
                .frame(width: wings.right, alignment: .trailing)
        }
        .frame(height: wings.frame.height)
        .background(UnevenRoundedRectangle(bottomLeadingRadius: 12, bottomTrailingRadius: 12, style: .continuous).fill(Palette.notch))
    }

    /// The strip in the menu bar with the sheet hanging below it. They stand apart inside the window, and what is between them is clear.
    private var panel: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let strip = stage.strip {
                closedStrip(strip.size)
                    .padding(.leading, stage.stripInset)
            }
            // The animation stays on the sheet: the window jumps when it opens, and the strip has to stand still through that.
            ZStack(alignment: .topLeading) {
                if stage.isOpen {
                    open
                        .padding(.leading, stage.sheetInset)
                        .transition(.opacity)
                }
            }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: stage.isOpen)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func closedStrip(_ size: CGSize) -> some View {
        let hasText = !stage.line.main.isEmpty || !stage.line.waiting.isEmpty
        return HStack(spacing: SurfaceMetrics.stripSpacing) {
            walrus(SurfaceMetrics.stripWalrus(height: size.height))
                // With no room for the words he still tells them to VoiceOver.
                .accessibilityValue(hasText ? "" : [stage.headerLine.main, stage.headerLine.waiting].filter { !$0.isEmpty }.joined(separator: ", "))
            if hasText {
                lineText(stage.line, size: SurfaceMetrics.stripText, waitingWeight: .semibold)
            }
        }
        .padding(.leading, SurfaceMetrics.stripLeading)
        .padding(.trailing, hasText ? SurfaceMetrics.stripTrailing : SurfaceMetrics.stripLeading)
        .frame(width: size.width, height: size.height, alignment: .leading)
        // The menu bar shows the wallpaper through it, so the text brings its own background to stay readable.
        // The continuous style leaves a stray piece of the outline beyond the rounded end.
        .background(
            Capsule(style: .circular)
                .fill(Palette.panel)
                .overlay(Capsule(style: .circular).strokeBorder(Palette.separator, lineWidth: 0.5))
                .padding(.vertical, 2)
        )
    }

    private func lineText(_ line: SurfaceLine, size: CGFloat, waitingWeight: Font.Weight) -> some View {
        HStack(spacing: SurfaceMetrics.pillSpacing) {
            if !line.main.isEmpty {
                Text(line.main)
                    .font(.system(size: size).monospacedDigit())
                    .foregroundStyle(stage.isQuiet ? Palette.text2 : Palette.text1)
                    .lineLimit(1)
            }
            if !line.waiting.isEmpty {
                Text(line.main.isEmpty ? line.waiting : "· \(line.waiting)")
                    .font(.system(size: size, weight: waitingWeight).monospacedDigit())
                    .foregroundStyle(Palette.waiting)
                    .lineLimit(1)
                    .layoutPriority(1)
            }
        }
    }

    // MARK: - Open

    private var open: some View {
        VStack(alignment: .leading, spacing: stage.hasNotch ? 12 : 10) {
            // Right below the same words in the strip it would only repeat them.
            if stage.strip == nil || stage.line != stage.headerLine {
                header
            }
            if mode == .technical {
                numbersRow
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    RequestCardList(model: model, surface: .notch)
                    sessions
                    failure
                }
            }
            // Room for what is around the list, so that the whole surface fits on the screen.
            .frame(maxHeight: max(stage.maximumHeight - 140, 80))
            .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer(minLength: 0)
                Button(L("Open Boris"), action: openMain).buttonStyle(PlainActionStyle(height: 22))
            }
        }
        .padding(EdgeInsets(top: stage.hasNotch ? 0 : 10, leading: 12, bottom: stage.hasNotch ? 14 : 12, trailing: 12))
        .frame(width: stage.openWidth)
        .background(GeometryReader { frame in
            Color.clear
                .onAppear { contentHeight(frame.size.height) }
                .onChange(of: frame.size.height) { _, height in contentHeight(height) }
        })
        .background(openShape)
    }

    @ViewBuilder private var openShape: some View {
        if stage.hasNotch {
            UnevenRoundedRectangle(bottomLeadingRadius: 18, bottomTrailingRadius: 18, style: .continuous).fill(Palette.notch)
        } else {
            // It hangs from the menu bar or from the top of the screen, so its top corners are only slightly round.
            let shape = UnevenRoundedRectangle(topLeadingRadius: 6, bottomLeadingRadius: 16, bottomTrailingRadius: 16, topTrailingRadius: 6, style: .continuous)
            shape
                .fill(Palette.panel)
                .overlay(shape.strokeBorder(Palette.separator, lineWidth: 0.5))
        }
    }

    @ViewBuilder private var header: some View {
        let line = stage.headerLine
        if stage.hasNotch {
            // The middle stays empty: the cutout is there. What he says can be longer than the room beside it, so it takes a second line.
            HStack(spacing: 0) {
                walrus(SurfaceMetrics.notchWalrus)
                Spacer(minLength: 8)
                Group {
                    if line.waiting.isEmpty {
                        Text(line.main).font(.system(size: 12)).foregroundStyle(Palette.text2)
                    } else {
                        Text(line.waiting).font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.waiting)
                    }
                }
                .lineLimit(2)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: max((stage.openWidth - stage.closedNotch.cutout) / 2 - 24, 0), alignment: .trailing)
            }
            .padding(.horizontal, 4)
            .frame(height: stage.closedNotch.frame.height)
        } else {
            HStack(spacing: SurfaceMetrics.pillSpacing) {
                // With a strip above, he is already there.
                if stage.strip == nil {
                    walrus(SurfaceMetrics.pillWalrus)
                }
                Text(line.main)
                    .font(.system(size: SurfaceMetrics.pillText))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if !line.waiting.isEmpty {
                    Text(line.waiting).font(.system(size: SurfaceMetrics.pillText, weight: .semibold)).foregroundStyle(Palette.waiting).lineLimit(1)
                }
            }
        }
    }

    /// A number must not lose its end, so on the narrower panel the row wraps instead.
    @ViewBuilder private var numbersRow: some View {
        let parts = SurfaceWords.numbersRow(model.surfaceNumbers, now: model.now)
        if !parts.isEmpty {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 14) {
                    ForEach(parts, id: \.self) { part in
                        Text(part).fixedSize()
                    }
                }
                Text(parts.joined(separator: " · "))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.system(size: 11).monospacedDigit())
            .foregroundStyle(Palette.text2)
            .padding(.horizontal, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder private var sessions: some View {
        // A session with a card above still counts among those at work. One without a held request has its notice among the cards only.
        let held = Set(model.hooks.pending.map(\.session))
        let list = model.work.waitingSessions.filter { held.contains($0.id) } + model.activeSessions
        if list.isEmpty {
            if lastFailure == nil, model.requestCount == 0 {
                VStack(spacing: 4) {
                    Text(L("Nothing is going on")).font(.system(size: 13, weight: .semibold))
                    Text(L("Nobody is waiting for an answer.")).font(.system(size: 12)).foregroundStyle(Palette.text2)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            }
        } else {
            VStack(alignment: .leading, spacing: 2) {
                Text(L("Active sessions"))
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(Palette.text2)
                    .padding(EdgeInsets(top: 0, leading: 4, bottom: 4, trailing: 4))
                ForEach(list) { session in
                    Button {
                        model.openSession(session.id)
                    } label: {
                        SurfaceSessionRow(session: session, mode: mode, now: model.now).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint(L("Opens the session"))
                }
            }
        }
    }

    private var lastFailure: SurfaceFailure? {
        SurfaceWords.lastFailure(in: model.work, mode: mode, now: model.now)
    }

    @ViewBuilder private var failure: some View {
        if let failure = lastFailure {
            Button {
                model.openSession(failure.sessionId)
            } label: {
                HStack(alignment: .top, spacing: 8) {
                    StatusGlyph(kind: .failed, size: 14)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(SurfaceSessionRow.nameAndDetail(failure.name, isFolder: failure.nameIsFolder, detail: failure.who))
                            .lineLimit(1)
                        Text(failure.what)
                            .foregroundStyle(Palette.redText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .font(.system(size: 12.5))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if let at = failure.at {
                        Text(WorkFormat.time(at)).font(.system(size: 11).monospacedDigit()).foregroundStyle(Palette.text2)
                    }
                }
                .padding(EdgeInsets(top: 8, leading: 10, bottom: 8, trailing: 10))
                .background(RoundedRectangle(cornerRadius: DesignMetrics.radiusLarge).fill(Palette.redSoft))
                .contentShape(Rectangle())
                .accessibilityElement(children: .combine)
            }
            .buttonStyle(.plain)
            .accessibilityHint(L("Opens the session"))
        }
    }
}

/// A session on one line, so that several fit in a surface that must stay small.
struct SurfaceSessionRow: View {
    var session: WorkSession
    var mode: DisplayMode
    var now: Date

    var body: some View {
        let trailing = SurfaceWords.sessionTrailing(session, mode: mode, now: now)
        let detail = SurfaceWords.sessionDetailParts(session, mode: mode)
        HStack(spacing: 8) {
            StatusGlyph(kind: StatusGlyph.Kind(session.state), size: 14)
            HStack(spacing: 0) {
                Text(Self.nameAndDetail(session.name(in: mode), isFolder: session.nameIsFolder, detail: detail.detail))
                    .lineLimit(1)
                // As in the mini window: what is being done gives way first, and the number of agents stays whole.
                if let agents = detail.agents {
                    Text(verbatim: " · \(agents)").foregroundStyle(Palette.text2).lineLimit(1).fixedSize()
                }
            }
            .font(.system(size: 12.5))
            .frame(maxWidth: .infinity, alignment: .leading)
            if !trailing.isEmpty {
                Text(trailing).font(.system(size: 11).monospacedDigit()).foregroundStyle(Palette.text2).lineLimit(1)
            }
        }
        .padding(.horizontal, 6)
        .frame(minHeight: 28)
        .accessibilityElement(children: .combine)
    }

    /// A folder is set in a monospaced font, a person's words are not, and what follows is quieter.
    static func nameAndDetail(_ name: String, isFolder: Bool, detail: String) -> AttributedString {
        var text = AttributedString(name)
        text.font = .system(size: 12.5, weight: .semibold, design: isFolder ? .monospaced : .default)
        guard !detail.isEmpty else { return text }
        var rest = AttributedString(" · \(detail)")
        rest.foregroundColor = Palette.text2
        return text + rest
    }
}

#if DEBUG
/// A made-up screen with the surface on it, placed by the same code as the real window. A snapshot cannot reach the real notch.
struct SurfacePreview: View {
    /// What the screen around the surface is like. Each case is a screen of `BORIS_SCREEN` under the same name.
    enum Scene: String {
        case notchClosed, notchOpen
        /// A menu bar with room.
        case panelClosed, panelOpen
        /// So many icons that only something short fits.
        case panelTight
        /// No room at all. Without a request nothing shows, and a request opens below the bar all the same.
        case panelFull, panelFullOpen
        /// A hidden menu bar: nothing on screen, then a request, then the same request after the person closed it.
        case panelHidden, panelHiddenOpen, panelHiddenWaiting

        var hasNotch: Bool { self == .notchClosed || self == .notchOpen }
        var isOpen: Bool { [.notchOpen, .panelOpen, .panelFullOpen, .panelHiddenOpen].contains(self) }
        var hidesBar: Bool { [.panelHidden, .panelHiddenOpen, .panelHiddenWaiting].contains(self) }
        var hasRequest: Bool { isOpen || self == .panelHiddenWaiting }
        var canvas: CGSize { CGSize(width: 1100, height: isOpen ? 640 : 90) }

        func iconsWidth(on width: CGFloat) -> CGFloat {
            switch self {
            case .panelTight: return width * 0.5
            case .panelFull, .panelFullOpen: return width * 0.8
            default: return 320
            }
        }
    }

    var model: AppModel
    var scene: Scene
    var canvas: CGSize

    /// As the real menu bar on a monitor without a notch is on the current macOS.
    private static let menuBar: CGFloat = 30
    private static let cutout = CGSize(width: 185, height: 37)
    private static let menusWidth: CGFloat = 360

    private var barHeight: CGFloat {
        if scene.hidesBar { return 0 }
        return scene.hasNotch ? Self.cutout.height : Self.menuBar
    }

    private var iconsWidth: CGFloat { scene.iconsWidth(on: canvas.width) }

    private var screen: SurfaceScreen {
        let frame = CGRect(origin: .zero, size: canvas)
        let notch = CGRect(x: (canvas.width - Self.cutout.width) / 2, y: canvas.height - Self.cutout.height, width: Self.cutout.width, height: Self.cutout.height)
        var visible = frame
        visible.size.height -= barHeight
        return SurfaceScreen(
            id: "preview",
            name: "Preview",
            frame: frame,
            visibleFrame: visible,
            notch: scene.hasNotch ? notch : nil,
            menuBar: barHeight,
            statusIconsMinX: scene.hidesBar ? nil : canvas.width - iconsWidth
        )
    }

    var body: some View {
        let stage = SurfaceStage()
        let inputs = SurfaceInputs(model: model)
        let placement = stage.arrange(inputs, on: screen, isOpen: scene.isOpen, contentHeight: canvas.height)
        return ZStack(alignment: .topLeading) {
            Palette.desk
            // An app's window right up to the menu bar: it is what the closed panel used to cover.
            UnevenRoundedRectangle(topLeadingRadius: 8, topTrailingRadius: 8, style: .continuous)
                .fill(Palette.window)
                .padding(.top, barHeight)
                .padding(.horizontal, 12)
            if barHeight > 0 {
                Palette.fill2.frame(height: barHeight)
                bar
            }
            if let placement {
                surface(stage, placement)
            }
            if scene.hasNotch {
                // The real cutout is black on black. Its outline shows that nothing runs behind it.
                Rectangle()
                    .strokeBorder(Palette.grey, style: StrokeStyle(lineWidth: 0.5, dash: [3, 3]))
                    .frame(width: Self.cutout.width, height: Self.cutout.height)
                    .offset(x: (canvas.width - Self.cutout.width) / 2)
            }
        }
        .frame(width: canvas.width, height: canvas.height, alignment: .topLeading)
        .clipped()
    }

    /// Places of the menus and the icons, to see that the panel stays off them.
    @ViewBuilder private var bar: some View {
        if !scene.hasNotch {
            ZStack(alignment: .leading) {
                HStack(spacing: 10) {
                    ForEach(0..<7, id: \.self) { _ in
                        Capsule().fill(Palette.fill2).frame(width: Self.menusWidth / 7 - 10, height: 10)
                    }
                }
                .padding(.leading, 12)
                HStack(spacing: 8) {
                    ForEach(0..<Int(iconsWidth / 32), id: \.self) { _ in
                        Circle().fill(Palette.fill2).frame(width: 16, height: 16)
                    }
                }
                .frame(width: iconsWidth, alignment: .trailing)
                .offset(x: canvas.width - iconsWidth - 8)
            }
            .frame(height: barHeight)
        }
    }

    private func surface(_ stage: SurfaceStage, _ placement: SurfacePlacement) -> some View {
        let frame = placement.frame
        let view = SurfaceView(model: model, stage: stage, speak: {}, openMain: {}, openSettings: {}, contentHeight: { _ in })
            .frame(width: frame.width, height: scene.isOpen ? nil : frame.height, alignment: .top)
            .fixedSize(horizontal: false, vertical: scene.isOpen)
        return Group {
            if scene.hasNotch {
                view.environment(\.colorScheme, .dark)
            } else {
                view
            }
        }
        .offset(x: frame.minX, y: canvas.height - frame.maxY)
    }
}

extension DevData {
    /// A failure for the surfaces to show, without changing what other screens see.
    func fillForSurface(_ model: AppModel) {
        fill(model)
        guard self != .empty else { return }
        let now = Date()
        let failed = WorkSession(
            id: "e1",
            environment: .terminal,
            cwd: "/x/shop-api",
            state: .finished,
            startedAt: now.addingTimeInterval(-3600),
            lastActivity: now.addingTimeInterval(-540),
            root: WorkNode(id: "e1", kind: .main, state: .finished, children: [
                WorkNode(id: "e2", kind: .subagent, title: self == .long ? "Миграции всех таблиц со сверкой и очень подробным отчётом для каждого отдела" : "Миграции", state: .failed, failure: FailureInfo(failureClass: .api, text: "overloaded"))
            ])
        )
        var work = model.work
        for project in work.projects.indices {
            for session in work.projects[project].sessions.indices where work.projects[project].sessions[session].state == .running {
                work.projects[project].sessions[session].root.contextTokens = self == .long && work.projects[project].sessions[session].id == "c1" ? 150_000 : 128_000
            }
        }
        work.projects.append(WorkProject(path: "/x/old-shop-api", sessions: [failed]))
        model.showForSnapshot(work: work, world: model.world, today: model.today, mood: model.mood)
    }
}
#endif
