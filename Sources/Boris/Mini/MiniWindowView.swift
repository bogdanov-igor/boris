import BorisCore
import SwiftUI

/// The small window under the menu bar icon: who needs you, how the limits stand, what is going on.
struct MiniWindowView: View {
    @Bindable var model: AppModel
    /// Takes the window away. Going to the main window starts with this, because a popover does not close by itself when its own app opens a window.
    var close: () -> Void = {}
    var openMain: () -> Void

    private var mode: DisplayMode { model.settings.displayMode }

    private var headline: (title: String, detail: String) {
        let waiting = model.requestCount
        let working = model.activeSessions.count
        let detail = working > 0 ? MainPhrases.sessionsAtWork(working) : L("Nothing is going on")
        return (waiting > 0 ? SurfaceWords.waiting(waiting) : (working > 0 ? L("At work") : L("Quiet")), detail)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            limits
            Divider()
            sessions
            Divider()
            footer
        }
        // A text whose values stay the same would otherwise keep the old language while the window is open.
        .id(model.settings.language)
        .frame(width: 360)
        .background(Palette.pop)
        .overlay(alignment: .topLeading) {
            WalrusLineOverlay(stage: model.walrus, tail: .up, maxWidth: 300).padding(EdgeInsets(top: 58, leading: 14, bottom: 0, trailing: 0))
        }
        .speedPlace(.miniWindow)
    }

    private var header: some View {
        HStack(spacing: 10) {
            WalrusView(mood: model.mood, outfit: model.outfit, size: 40, style: .simple, stage: model.walrus) { _ = model.pokeWalrus() }
            VStack(alignment: .leading, spacing: 1) {
                Text(headline.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(model.requestCount > 0 ? Palette.waiting : Palette.text1)
                Text(headline.detail).font(.system(size: 11.5)).foregroundStyle(Palette.text2)
            }
            Spacer(minLength: 0)
        }
        .padding(EdgeInsets(top: 12, leading: 14, bottom: 10, trailing: 14))
    }

    private var limits: some View {
        VStack(alignment: .leading, spacing: 7) {
            LimitsBlock(usage: model.world.usage, now: model.now, compact: true)
            if model.world.usage != nil || model.world.account == .signedIn { LimitsFreshness(model: model, compact: true) }
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(L("Tokens today")).font(.system(size: 12)).foregroundStyle(Palette.text2)
                Spacer(minLength: 8)
                Text(model.usage.todayText(model.today))
                    .font(model.usage.book != nil ? .system(size: 12, weight: .semibold).monospacedDigit() : .system(size: 12).italic())
                    .foregroundStyle(model.usage.book != nil ? Palette.text1 : Palette.text3)
                if let estimate = UsageFormat.estimateShort(model.usage.book?.report(.today).estimate) {
                    Text(verbatim: "· \(estimate)").font(.system(size: 11)).foregroundStyle(Palette.text3).lineLimit(1)
                }
            }
            if mode == .technical, model.usage.book != nil {
                // A number must not lose its end, and Russian ones are long, so the row takes the room each one needs and folds when that is too much.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        breakdown(L("in %@", WorkFormat.tokens(model.today.input)))
                        Spacer(minLength: 0)
                        breakdown(L("out %@", WorkFormat.tokens(model.today.output)))
                        Spacer(minLength: 0)
                        breakdown(L("cache r. %@", WorkFormat.tokens(model.today.cacheRead)))
                        Spacer(minLength: 0)
                        breakdown(L("cache w. %@", WorkFormat.tokens(model.today.cacheWrite)))
                    }
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 2) {
                        GridRow {
                            breakdown(L("in %@", WorkFormat.tokens(model.today.input)))
                            breakdown(L("out %@", WorkFormat.tokens(model.today.output)))
                        }
                        GridRow {
                            breakdown(L("cache r. %@", WorkFormat.tokens(model.today.cacheRead)))
                            breakdown(L("cache w. %@", WorkFormat.tokens(model.today.cacheWrite)))
                        }
                    }
                }
            }
            SourcesIncompleteNote(settings: model.settings.sources)
            Rectangle().fill(Palette.separator).frame(height: 1).padding(.top, 1)
            MacLoadBlock(model: model, kind: mode == .technical ? .miniTechnical : .miniSimple)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func breakdown(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10.5).monospacedDigit())
            .foregroundStyle(Palette.text2)
            .fixedSize()
    }

    private var idleLine: String {
        guard let count = model.usage.book?.sessionsToday, count > 0 else { return L("Nobody is waiting for an answer.") }
        return count == 1 ? L("Nobody is waiting for an answer. There was %lld session today.", count) : L("Nobody is waiting for an answer. There were %lld sessions today.", count)
    }

    @ViewBuilder private var sessions: some View {
        if model.requestCount == 0, model.activeSessions.isEmpty {
            VStack(spacing: 4) {
                if model.settings.sources.allOff {
                    Text(L("All sources are off")).font(.system(size: 13, weight: .semibold))
                    Text(L("Claude works as usual. Boris reads nothing until you turn a source back on."))
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.text2)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 14)
                } else {
                    Text(L("Nothing is going on")).font(.system(size: 13, weight: .semibold))
                    Text(idleLine)
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.text2)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(EdgeInsets(top: 22, leading: 14, bottom: 22, trailing: 14))
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    RequestCardList(model: model, surface: .mini)
                    list(L("Active sessions"), model.activeSessions, color: Palette.text2)
                }
                .padding(EdgeInsets(top: 8, leading: 8, bottom: 10, trailing: 8))
            }
            .frame(maxHeight: 480)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private func list(_ title: String, _ sessions: [WorkSession], color: Color) -> some View {
        if !sessions.isEmpty {
            Text(title)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(color)
                .padding(.horizontal, 6)
            ForEach(sessions) { session in
                RowButton {
                    open(session)
                } label: {
                    SessionRow(session: session, mode: mode, trailing: trailing(session), compact: true, lineEnd: mode == .technical ? WorkPhrases.contextLine(session) ?? "" : "")
                }
                .accessibilityHint(L("Opens the session"))
            }
        }
    }

    func open(_ session: WorkSession) {
        close()
        model.openSession(session.id)
    }

    private func trailing(_ session: WorkSession) -> String {
        if mode == .technical, let tokens = session.root.tokens { return WorkFormat.tokens(tokens.total) }
        return ""
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Text(model.settings.hotKeyEnabled ? L("%@ opens this window", model.settings.hotKey.label) : "")
                .font(.system(size: 11))
                .foregroundStyle(Palette.text3)
                .lineLimit(1)
            Spacer(minLength: 0)
            Button(L("Open Boris")) {
                close()
                openMain()
            }
            .buttonStyle(PlainActionStyle())
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}
