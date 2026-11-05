import BorisCore
import SwiftUI

/// The left side of the page: where the data starts, the total, the chart and the breakdown.
struct SpendTokensColumn: View {
    @Bindable var model: AppModel

    private var mode: DisplayMode { model.settings.displayMode }
    private var usage: UsageModel { model.usage }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let book = usage.book {
                note(book)
                let report = book.report(usage.period)
                totals(report)
                if report.usage.total > 0 {
                    SpendTable(lines: report.lines(usage.breakdown), breakdown: usage.breakdown, today: book.today, mode: mode)
                }
            } else {
                noData
            }
        }
    }

    private func note(_ book: TokenBook) -> some View {
        Group {
            if let earliest = book.earliestDay {
                Text(L("Data from %@: Claude keeps logs for a limited time.", UsageFormat.longDay(earliest, today: book.today)))
            } else {
                Text(L("Claude has no logs yet."))
            }
        }
        .font(.system(size: 11.5))
        .foregroundStyle(Palette.text3)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func totals(_ report: PeriodReport) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(WorkFormat.tokens(report.usage.total))
                    .font(.system(size: 22, weight: .semibold).monospacedDigit())
                Text(UsageFormat.periodCaption(usage.period))
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.text2)
            }
            if report.usage.total == 0 {
                Text(L("No work in this period."))
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.text3)
            } else if report.chartDays.count > 1, report.chartDays.contains(where: { $0.usage.total > 0 }) {
                SpendChart(days: report.chartDays, today: usage.book?.today ?? "", mode: mode)
                if usage.book?.chartLeavesOutDays(usage.period) == true {
                    Text(L("The chart shows the last %lld days, the total covers all of them.", report.chartDays.count))
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.text3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(RoundedRectangle(cornerRadius: DesignMetrics.radiusLarge).strokeBorder(Palette.separator))
    }

    private var noData: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L("no data"))
                .font(.system(size: 15).italic())
                .foregroundStyle(Palette.text3)
            Text(L("The tokens appear after the first pass over Claude's logs."))
                .font(.system(size: 12))
                .foregroundStyle(Palette.text2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(RoundedRectangle(cornerRadius: DesignMetrics.radiusLarge).strokeBorder(Palette.separator))
    }
}

/// Tokens by day. One colour says how much, and in the technical view the four kinds of tokens are stacked.
private struct SpendChart: View {
    var days: [TokenLine]
    var today: String
    var mode: DisplayMode

    private static let height: CGFloat = 160
    private static let series: [(color: Color, part: KeyPath<TokenUsage, Int>)] = [
        (Palette.chartCacheWrite, \.cacheWrite),
        (Palette.chartCacheRead, \.cacheRead),
        (Palette.chartOutput, \.output),
        (Palette.chartInput, \.input),
    ]

    /// Labels fit on every bar only when there are few of them, and a number on every bar of a month reads as noise.
    private var showsValues: Bool { days.count <= 14 }
    private var spacing: CGFloat { days.count <= 14 ? 14 : days.count <= 40 ? 4 : 1 }
    private var labelStep: Int { max(1, Int((Double(days.count) / 8).rounded(.up))) }
    private var largest: Int { days.map(\.usage.total).max() ?? 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .bottom, spacing: spacing) {
                ForEach(days) { day in
                    column(day)
                }
            }
            .frame(height: Self.height + (showsValues ? 16 : 0), alignment: .bottom)
            .padding(.horizontal, 4)
            Rectangle().fill(Palette.separator).frame(height: 1)
            HStack(spacing: spacing) {
                ForEach(Array(days.enumerated()), id: \.element.id) { index, day in
                    Text(labelShown(index) ? title(day) : "")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Palette.text3)
                        .lineLimit(1)
                        .fixedSize()
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 14)
            .padding(.horizontal, 4)
            if mode == .technical {
                legend.padding(.top, 6)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L("Tokens by day"))
    }

    /// The newest day always keeps its label, and the others count back from it.
    private func labelShown(_ index: Int) -> Bool {
        (days.count - 1 - index) % labelStep == 0
    }

    private func title(_ day: TokenLine) -> String {
        UsageFormat.lineTitle(day.key, today: today, mode: mode)
    }

    private func column(_ day: TokenLine) -> some View {
        let value = WorkFormat.tokens(day.usage.total)
        return VStack(spacing: 1) {
            if showsValues, day.usage.total > 0 {
                Text(value)
                    .font(.system(size: 10.5).monospacedDigit())
                    .foregroundStyle(Palette.text2)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .frame(height: 14)
            }
            bars(day)
        }
        .frame(maxWidth: .infinity, alignment: .bottom)
        .help("\(title(day)): \(value)")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title(day)): \(value)")
    }

    @ViewBuilder private func bars(_ day: TokenLine) -> some View {
        let total = day.usage.total
        let height = largest > 0 ? Self.height * CGFloat(total) / CGFloat(largest) : 0
        if total == 0 {
            EmptyView()
        } else if mode == .simple {
            UnevenRoundedRectangle(topLeadingRadius: 2, topTrailingRadius: 2)
                .fill(Palette.meter)
                .frame(height: max(height, 2))
        } else {
            VStack(spacing: 1) {
                ForEach(Self.series.indices, id: \.self) { index in
                    let part = day.usage[keyPath: Self.series[index].part]
                    if part > 0 {
                        Rectangle()
                            .fill(Self.series[index].color)
                            .frame(height: max(height * CGFloat(part) / CGFloat(total), 2))
                    }
                }
            }
            .clipShape(UnevenRoundedRectangle(topLeadingRadius: 2, topTrailingRadius: 2))
        }
    }

    private var legend: some View {
        HStack(spacing: 14) {
            legendItem(Palette.chartInput, L("Input"))
            legendItem(Palette.chartOutput, L("Output"))
            legendItem(Palette.chartCacheRead, L("Cache reads"))
            legendItem(Palette.chartCacheWrite, L("Cache writes"))
        }
        .font(.system(size: 11.5))
        .foregroundStyle(Palette.text2)
    }

    private func legendItem(_ color: Color, _ title: String) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 10, height: 10)
            Text(title).lineLimit(1)
        }
    }
}

/// The numbers of the chosen breakdown. The simple view leaves the kinds of tokens out.
private struct SpendTable: View {
    var lines: [TokenLine]
    var breakdown: TokenBreakdown
    var today: String
    var mode: DisplayMode

    private var firstColumnTitle: String {
        switch breakdown {
        case .days: return L("Day")
        case .environments: return L("Environment")
        case .projects: return L("Project")
        case .models: return L("Model")
        case .agents: return L("Agents")
        }
    }

    /// A day is short, while the name of a project needs the room.
    private var firstColumn: CGFloat {
        switch (breakdown, mode) {
        case (.days, .simple): return 90
        case (.days, .technical): return 76
        case (_, .simple): return 190
        case (_, .technical): return 120
        }
    }

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            row(
                first: firstColumnTitle,
                cells: mode == .technical
                    ? [L("Input"), L("Output"), L("Cache reads"), L("Cache writes"), L("Total")]
                    : [L("Tokens")],
                last: L("Estimate"),
                isHead: true
            )
            .padding(.bottom, 6)
            .overlay(alignment: .bottom) { Rectangle().fill(Palette.separator).frame(height: 1) }
            ForEach(lines) { line in
                row(
                    first: UsageFormat.lineTitle(line.key, today: today, mode: mode),
                    cells: mode == .technical
                        ? [line.usage.input, line.usage.output, line.usage.cacheRead, line.usage.cacheWrite, line.usage.total].map(WorkFormat.tokens)
                        : [WorkFormat.tokens(line.usage.total)],
                    last: UsageFormat.estimate(line.estimate),
                    isHead: false,
                    fullName: fullName(line)
                )
                .frame(minHeight: 26)
                .overlay(alignment: .bottom) { Rectangle().fill(Palette.separator).frame(height: 1) }
            }
        }
    }

    /// The whole path, for those who have several folders with the same name.
    private func fullName(_ line: TokenLine) -> String? {
        if case .project(let path?) = line.key { return path }
        return nil
    }

    private func row(first: String, cells: [String], last: String, isHead: Bool, fullName: String? = nil) -> some View {
        HStack(spacing: 10) {
            Text(first)
                .foregroundStyle(isHead ? Palette.text3 : Palette.text1)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: firstColumn, alignment: .leading)
                .help(fullName ?? "")
            ForEach(cells.indices, id: \.self) { index in
                Text(cells[index])
                    .foregroundStyle(isHead ? Palette.text3 : Palette.text1)
                    .lineLimit(isHead ? 2 : 1)
                    .minimumScaleFactor(0.8)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            Text(last)
                .foregroundStyle(isHead ? Palette.text3 : Palette.text2)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(width: 76, alignment: .trailing)
        }
        .font(.system(size: isHead ? 11 : 12).monospacedDigit())
        .padding(.horizontal, 8)
        .accessibilityElement(children: .combine)
    }
}
