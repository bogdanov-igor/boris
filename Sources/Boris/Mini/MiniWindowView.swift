import BorisCore
import SwiftUI

/// The small window under the menu bar icon: who needs you, how the limits stand, what is going on.
struct MiniWindowView: View {
    @Bindable var model: AppModel
    var openMain: () -> Void

    private var mode: DisplayMode { model.settings.displayMode }

    private var headline: (title: String, detail: String) {
        let waiting = model.requestCount
        let working = model.activeSessions.count
        let detail = working > 0 ? MainPhrases.sessionsAtWork(working) : L("Nothing is going on")
        return (waiting > 0 ? L("%lld waiting for you", waiting) : (working > 0 ? L("At work") : L("Quiet")), detail)
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
        .frame(width: 360)
        .background(Palette.pop)
        .overlay(alignment: .topLeading) {
            WalrusLineOverlay(stage: model.walrus, tail: .up, maxWidth: 300).padding(EdgeInsets(top: 58, leading: 14, bottom: 0, trailing: 0))
        }
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
            if let fetched = model.world.usage?.fetchedAt {
                Text(L("updated %@", WorkFormat.ago(model.now.timeIntervalSince(fetched))))
                    .font(.system(size: 11)).foregroundStyle(Palette.text3)
            }
            HStack(alignment: .firstTextBaseline) {
                Text(L("Tokens today")).font(.system(size: 12)).foregroundStyle(Palette.text2)
                Spacer(minLength: 8)
                Text(model.usage.todayText(model.today))
                    .font(model.usage.book != nil ? .system(size: 12, weight: .semibold).monospacedDigit() : .system(size: 12).italic())
                    .foregroundStyle(model.usage.book != nil ? Palette.text1 : Palette.text3)
            }
            if mode == .technical, model.usage.book != nil {
                HStack(spacing: 4) {
                    breakdown(L("in %@", WorkFormat.tokens(model.today.input)))
                    breakdown(L("out %@", WorkFormat.tokens(model.today.output)))
                    breakdown(L("cache r. %@", WorkFormat.tokens(model.today.cacheRead)))
                    breakdown(L("cache w. %@", WorkFormat.tokens(model.today.cacheWrite)))
                }
            }
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
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var sessions: some View {
        if model.requestCount == 0, model.activeSessions.isEmpty {
            VStack(spacing: 4) {
                Text(L("Nothing is going on")).font(.system(size: 13, weight: .semibold))
                Text(L("Nobody is waiting for an answer.")).font(.system(size: 12)).foregroundStyle(Palette.text2)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 22)
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
                SessionRow(session: session, mode: mode, trailing: trailing(session), compact: true)
            }
        }
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
            Button(L("Open Boris"), action: openMain)
                .buttonStyle(PlainActionStyle())
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}
