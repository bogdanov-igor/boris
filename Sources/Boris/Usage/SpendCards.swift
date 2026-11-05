import BorisCore
import SwiftUI

/// The right side of the page: limits, the estimate, real extra spend and the load on this Mac.
struct SpendCardsColumn: View {
    @Bindable var model: AppModel

    private var mode: DisplayMode { model.settings.displayMode }
    private var usage: UsageSnapshot? { model.world.usage }
    private var account: ClaudeAccount { model.world.account }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SpendLimitsCard(model: model)
            estimate
            SpendExtraCard(card: UsageCards.extra(usage: usage, account: account))
            SpendCard {
                MacLoadBlock(model: model, kind: mode == .technical ? .pageTechnical : .pageSimple)
            }
        }
    }

    private var estimate: some View {
        SpendCard {
            Text(L("Estimate at API prices")).font(.system(size: 12.5, weight: .semibold))
            if let book = model.usage.book {
                let report = book.report(model.usage.period)
                Text(UsageFormat.estimate(report.estimate))
                    .font(report.estimate.isKnown ? .system(size: 22, weight: .semibold).monospacedDigit() : .system(size: 15).italic())
                    .foregroundStyle(report.estimate.isKnown ? Palette.text1 : Palette.text3)
                Text(caption(book, report))
                    .font(.system(size: 11.5))
                    .lineSpacing(2)
                    .foregroundStyle(Palette.text2)
                    .fixedSize(horizontal: false, vertical: true)
                if report.estimate.unpricedTokens > 0 {
                    Text(L("Without %@ tokens of models whose price Boris does not know.", WorkFormat.tokens(report.estimate.unpricedTokens)))
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.text3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(L("Prices as of %@", UsageFormat.longDay(PriceTable.takenOn, today: book.today)))
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.text3)
            } else {
                Text(L("no data")).font(.system(size: 15).italic()).foregroundStyle(Palette.text3)
                Text(UsageFormat.estimateNote(account: account))
                    .font(.system(size: 11.5))
                    .foregroundStyle(Palette.text2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func caption(_ book: TokenBook, _ report: PeriodReport) -> String {
        let note = UsageFormat.estimateNote(account: account)
        guard model.usage.period != .today else { return "\(UsageFormat.periodCaption(.today)). \(note)" }
        return L("%@, today %@. %@", UsageFormat.periodCaption(model.usage.period), UsageFormat.estimate(book.report(.today).estimate), note)
    }
}

/// The frame shared by the blocks of this page.
struct SpendCard<Content: View>: View {
    var spacing: CGFloat = 6
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) { content() }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(RoundedRectangle(cornerRadius: DesignMetrics.radiusLarge).strokeBorder(Palette.separator))
    }
}

private struct SpendLimitsCard: View {
    @Bindable var model: AppModel

    private var card: LimitsCard { UsageCards.limits(usage: model.world.usage, account: model.world.account) }

    var body: some View {
        switch card {
        case .hidden:
            EmptyView()
        case .windows(let windows):
            SpendCard(spacing: 8) {
                title
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(windows) { window in
                        row(window)
                    }
                }
                .font(.system(size: 12))
                freshness
            }
        case .noData:
            SpendCard(spacing: 8) {
                title
                Text(L("no data")).font(.system(size: 12).italic()).foregroundStyle(Palette.text3)
                Text(model.world.account == .gateway ? L("Claude does not report the gateway's budget in its files.") : L("Claude has not reported limits for this account."))
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.text3)
                    .fixedSize(horizontal: false, vertical: true)
                // A gateway has no plan to ask about, so there is nothing to refresh.
                if model.world.account != .gateway { freshness }
            }
        }
    }

    private var title: some View {
        Text(L("Limits")).font(.system(size: 12.5, weight: .semibold))
    }

    private func row(_ window: UsageWindow) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(UsageFormat.windowTitle(window))
                .foregroundStyle(Palette.text2)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: 92, alignment: .leading)
                .help(UsageFormat.windowTitle(window))
            VStack(alignment: .leading, spacing: 3) {
                Meter(percent: window.percent).frame(height: 15)
                // No empty line under a window that gives no time.
                if let resets = window.resetsAt {
                    Text(WorkFormat.resets(resets, now: model.now))
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.text3)
                        .lineLimit(1)
                }
            }
            Text(WorkFormat.percent(window.percent))
                .fontWeight(.semibold)
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize()
        }
        .accessibilityElement(children: .combine)
    }

    /// How old the numbers are, and a way to ask for new ones. A failed attempt is said quietly: the work itself is fine.
    private var freshness: some View {
        HStack(spacing: 6) {
            if let line = ageLine {
                Text(line)
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.text3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button(L("Refresh")) { model.usageRefresher.refreshNow() }
                .buttonStyle(SpendSmallButton())
                .disabled(model.usageRefresher.refreshing)
        }
    }

    private var ageLine: String? {
        let age = model.world.usage?.fetchedAt.map { L("updated %@", WorkFormat.ago(model.now.timeIntervalSince($0))) }
        if model.usageRefresher.refreshing {
            return age.map { "\($0) · \(L("refreshing…"))" } ?? L("refreshing…")
        }
        if model.usageRefresher.failed {
            return age.map { "\($0) · \(L("could not refresh"))" } ?? L("could not refresh")
        }
        return age
    }
}

private struct SpendSmallButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11))
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 8)
            .frame(height: 20)
            .foregroundStyle(Palette.text2)
            .background(RoundedRectangle(cornerRadius: DesignMetrics.radiusSmall).fill(Palette.fill1))
            .opacity(configuration.isPressed ? 0.75 : 1)
            .contentShape(Rectangle())
    }
}

private struct SpendExtraCard: View {
    var card: ExtraCard

    var body: some View {
        switch card {
        case .hidden:
            EmptyView()
        case .spent(let used, let limit, let currency):
            SpendCard {
                title
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(UsageFormat.money(used, currency: currency))
                        .font(.system(size: 22, weight: .semibold).monospacedDigit())
                    Text(limit.map { L("of %@ a month", UsageFormat.money($0, currency: currency)) } ?? L("this month, no limit set"))
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.text2)
                        .lineLimit(2)
                }
                if let limit {
                    Meter(percent: used / limit * 100)
                }
                Text(L("Money really charged beyond the plan."))
                    .font(.system(size: 11.5))
                    .foregroundStyle(Palette.text2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .off:
            SpendCard {
                title
                Text(L("Extra spend is off")).font(.system(size: 15, weight: .semibold)).foregroundStyle(Palette.text2)
                Text(L("Nothing is charged beyond the plan."))
                    .font(.system(size: 11.5))
                    .foregroundStyle(Palette.text2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .noData:
            SpendCard {
                title
                Text(L("no data")).font(.system(size: 15).italic()).foregroundStyle(Palette.text3)
                HStack(spacing: 4) {
                    Text(L("Boris cannot see them. You can check on"))
                        .foregroundStyle(Palette.text2)
                        .fixedSize(horizontal: false, vertical: true)
                    if let link = URL(string: "https://claude.ai/settings/usage") {
                        Link(destination: link) {
                            Text(verbatim: "claude.ai").foregroundStyle(Palette.waiting)
                        }
                    }
                }
                .font(.system(size: 11.5))
            }
        }
    }

    private var title: some View {
        Text(L("Real extra spend")).font(.system(size: 12.5, weight: .semibold))
    }
}
