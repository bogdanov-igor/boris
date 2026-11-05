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

    static func pillWidth(_ line: SurfaceLine) -> CGFloat {
        6 + pillWalrus + pillSpacing + textWidth(line, size: pillText) + 14 + 2
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
            if stage.isOpen {
                open
            } else if stage.hasNotch {
                closedNotch
            } else {
                closedPill
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

    private var mode: DisplayMode { model.settings.displayMode }

    /// His picture leaves room for tall hats, so it is drawn larger than the place it takes in the row.
    private func walrus(_ size: CGFloat) -> some View {
        Button(action: speak) {
            WalrusView(mood: model.mood, outfit: model.outfit, size: size * 1.3, style: .simple)
                .frame(width: size, height: size)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L("Boris"))
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

    private var closedPill: some View {
        HStack(spacing: SurfaceMetrics.pillSpacing) {
            walrus(SurfaceMetrics.pillWalrus)
            lineText(stage.line, size: SurfaceMetrics.pillText, waitingWeight: .semibold)
        }
        .padding(.leading, 6)
        .padding(.trailing, 14)
        .frame(height: SurfaceGeometry.closedPillHeight)
        // The continuous style leaves a stray piece of the outline beyond the rounded end.
        .background(Capsule(style: .circular).fill(Palette.panel))
        .overlay(Capsule(style: .circular).strokeBorder(Palette.separator, lineWidth: 0.5))
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
            header
            if mode == .technical {
                numbersRow
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    RequestCardList(model: model)
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
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Palette.panel)
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Palette.separator, lineWidth: 0.5))
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
                walrus(SurfaceMetrics.pillWalrus)
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
        let numbers = SurfaceNumbers(work: model.work, requests: model.requestCount, today: model.today, usage: model.world.usage)
        let parts = SurfaceWords.numbersRow(numbers, now: model.now)
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
        let list = model.work.waitingSessions + model.activeSessions
        if list.isEmpty {
            if lastFailure == nil, model.hooks.pending.isEmpty {
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
                    SurfaceSessionRow(session: session, mode: mode, now: model.now)
                }
            }
        }
    }

    private var lastFailure: SurfaceFailure? {
        SurfaceWords.lastFailure(in: model.work, mode: mode, now: model.now)
    }

    @ViewBuilder private var failure: some View {
        if let failure = lastFailure {
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
            .accessibilityElement(children: .combine)
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
        HStack(spacing: 8) {
            StatusGlyph(kind: StatusGlyph.Kind(session.state), size: 14)
            Text(Self.nameAndDetail(session.displayName, isFolder: session.nameIsFolder, detail: SurfaceWords.sessionDetail(session, mode: mode)))
                .font(.system(size: 12.5))
                .lineLimit(1)
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
    var model: AppModel
    var hasNotch: Bool
    var isOpen: Bool
    var canvas: CGSize

    private static let menuBar: CGFloat = 24
    private static let cutout = CGSize(width: 185, height: 37)

    private var screen: SurfaceScreen {
        let frame = CGRect(origin: .zero, size: canvas)
        let notch = CGRect(x: (canvas.width - Self.cutout.width) / 2, y: canvas.height - Self.cutout.height, width: Self.cutout.width, height: Self.cutout.height)
        var visible = frame
        visible.size.height -= hasNotch ? Self.cutout.height : Self.menuBar
        return SurfaceScreen(id: "preview", name: "Preview", frame: frame, visibleFrame: visible, notch: hasNotch ? notch : nil)
    }

    var body: some View {
        let stage = SurfaceStage()
        let frame = stage.arrange(SurfaceInputs(model: model), on: screen, isOpen: isOpen, contentHeight: canvas.height, spoken: nil)
        let surface = SurfaceView(model: model, stage: stage, speak: {}, openMain: {}, openSettings: {}, contentHeight: { _ in })
            .frame(width: frame.width, height: isOpen ? nil : frame.height, alignment: .top)
            .fixedSize(horizontal: false, vertical: isOpen)
        return ZStack(alignment: .topLeading) {
            Palette.desk
            Palette.fill2.frame(height: hasNotch ? Self.cutout.height : Self.menuBar)
            Group {
                if hasNotch {
                    surface.environment(\.colorScheme, .dark)
                } else {
                    surface
                }
            }
            .offset(x: frame.minX, y: canvas.height - frame.maxY)
            if hasNotch {
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
