import BorisCore
import BorisData
import SwiftUI

/// What the work with Claude costs: tokens, limits, money and the load on this Mac.
struct SpendPage: View {
    @Bindable var model: AppModel
    @State private var width: CGFloat = 1000

    /// The room for the column of tokens, the cards beside it and the margins.
    static let twoColumnsFrom: CGFloat = 500 + 22 + 320 + 48

    /// Decided by the room there is, not by how long the names in the table happen to be:
    /// otherwise a new period, breakdown or project could rearrange the page under the person, at the same window size.
    static func hasTwoColumns(_ width: CGFloat) -> Bool { width >= twoColumnsFrom }

    var body: some View {
        VStack(spacing: 0) {
            if model.usage.book == nil {
                SpendFillingBanner(progress: model.usage.progress)
            }
            ScrollView {
                Group {
                    if Self.hasTwoColumns(width) {
                        HStack(alignment: .top, spacing: 22) {
                            SpendTokensColumn(model: model).frame(maxWidth: .infinity)
                            SpendCardsColumn(model: model).frame(width: 320)
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 18) {
                            SpendTokensColumn(model: model)
                            SpendCardsColumn(model: model)
                        }
                    }
                }
                .padding(EdgeInsets(top: 16, leading: 24, bottom: 24, trailing: 24))
            }
            .onGeometryChange(for: CGFloat.self, of: { $0.size.width }, action: { width = $0 })
        }
    }
}

/// The controls in the page's header.
struct SpendHeaderControls: View {
    @Bindable var usage: UsageModel

    var body: some View {
        ChoiceBar(
            options: UsagePeriod.allCases.map { ($0, UsageFormat.periodTitle($0)) },
            selection: $usage.period,
            label: L("Period")
        )
        HStack(spacing: 6) {
            Text(L("Breakdown")).font(.system(size: 12)).foregroundStyle(Palette.text2).lineLimit(1).fixedSize()
            Picker(L("Breakdown"), selection: $usage.breakdown) {
                ForEach(TokenBreakdown.allCases, id: \.self) { breakdown in
                    Text(UsageFormat.breakdownTitle(breakdown)).tag(breakdown)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .controlSize(.small)
            .fixedSize()
        }
    }
}

/// The first pass over the logs takes a while and holds nothing up, so the page says what it is waiting for.
private struct SpendFillingBanner: View {
    var progress: WorkEngine.TokenProgress?

    private var share: Double? {
        guard let progress, progress.total > 0 else { return nil }
        return min(Double(progress.done) / Double(progress.total), 1)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            StatusGlyph(kind: .running)
            VStack(alignment: .leading, spacing: 2) {
                Text(L("Gathering the statistics")).font(.system(size: 12.5, weight: .semibold))
                Text(L("Reading Claude's logs for the past days. Everything else keeps working, and the numbers appear as soon as the logs are read."))
                    .font(.system(size: 12))
                    .lineSpacing(2)
                    .foregroundStyle(Palette.text2)
                    .fixedSize(horizontal: false, vertical: true)
                if let share {
                    GeometryReader { frame in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Palette.meterTrack)
                            Capsule().fill(Palette.running).frame(width: frame.size.width * share)
                        }
                    }
                    .frame(height: 4)
                    .padding(.top, 6)
                    .accessibilityValue(WorkFormat.percent(share * 100))
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.fill1)
        .overlay(alignment: .bottom) { Rectangle().fill(Palette.separator).frame(height: 1) }
    }
}
