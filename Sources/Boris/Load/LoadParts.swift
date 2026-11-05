import AppKit
import BorisCore
import SwiftUI

extension Palette {
    static let loadGap = Color(DesignTokens.loadGap)

    static func load(_ group: LoadGroup) -> Color {
        switch group {
        case .claude: return Color(DesignTokens.loadClaude)
        case .cowork: return Color(DesignTokens.loadCowork)
        case .vsCode: return Color(DesignTokens.loadVSCode)
        case .cursor: return Color(DesignTokens.loadCursor)
        case .claudeDesktop: return Color(DesignTokens.loadDesktop)
        case .boris: return Color(DesignTokens.loadBoris)
        case .rest: return Color(DesignTokens.loadRest)
        }
    }
}

/// Tells when the view it sits in can really be seen.
///
/// `onDisappear` is not enough for this: checked on macOS 26, it does not fire when a window closes or a popover hides, and `onAppear` fires
/// only for the popover's first opening. The window's occlusion state does change in all these cases, and also when the window is minimised or covered.
struct VisibilityProbe: NSViewRepresentable {
    var onChange: (Bool) -> Void

    func makeNSView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ view: ProbeView, context: Context) {
        view.onChange = onChange
    }

    /// The window stays when only this view goes away, for example on switching to another page.
    static func dismantleNSView(_ view: ProbeView, coordinator: ()) {
        view.onChange?(false)
        view.onChange = nil
    }

    final class ProbeView: NSView {
        var onChange: ((Bool) -> Void)?
        private var observer: NSObjectProtocol?

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            super.viewWillMove(toWindow: newWindow)
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window {
                observer = NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.report() }
                }
            }
            report()
        }

        private func report() {
            onChange?(window?.occlusionState.contains(.visible) == true)
        }
    }
}

/// Sizes of a row, from `B-Load`.
struct LoadRowStyle {
    var titleWidth: CGFloat
    var valueWidth: CGFloat
    var fontSize: CGFloat
    var barHeight: CGFloat
    var gap: CGFloat

    static let page = LoadRowStyle(titleWidth: 86, valueWidth: 48, fontSize: 12, barHeight: 8, gap: 10)
    static let mini = LoadRowStyle(titleWidth: 74, valueWidth: 38, fontSize: 11.5, barHeight: 4, gap: 6)
    static let session = LoadRowStyle(titleWidth: 86, valueWidth: 60, fontSize: 12, barHeight: 8, gap: 10)
}

enum LoadReading: Equatable {
    /// The first reading is a moment away.
    case waiting
    case noData
    case value(String)
}

/// A bar of coloured parts. Without data it is dashed, so it cannot be taken for an empty one.
struct LoadBar: View {
    struct Segment {
        var percent: Double
        var color: Color
    }

    var segments: [Segment]
    var height: CGFloat
    var dashed = false

    var body: some View {
        if dashed {
            RoundedRectangle(cornerRadius: 3)
                .strokeBorder(Palette.text3, style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                .opacity(0.6)
                .frame(height: height)
        } else {
            GeometryReader { frame in
                HStack(spacing: 0) {
                    ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                        Rectangle()
                            .fill(segment.color)
                            .frame(width: frame.size.width * min(max(segment.percent, 0), 100) / 100)
                            .overlay(alignment: .trailing) {
                                if segments.count > 1 { Rectangle().fill(Palette.loadGap).frame(width: 1) }
                            }
                    }
                    Spacer(minLength: 0)
                }
            }
            .frame(height: height)
            .background(Palette.meterTrack)
            .clipShape(RoundedRectangle(cornerRadius: 3))
        }
    }
}

struct LoadLegendItem {
    var color: Color
    var text: String
}

/// Places its parts in a line and wraps them when the line is full.
struct LoadFlowLayout: Layout {
    var horizontal: CGFloat = 12
    var vertical: CGFloat = 4

    /// Its natural size, unless that is wider than the line: then it wraps inside the line instead of spilling out of the card.
    private func size(of subview: LayoutSubview, width: CGFloat) -> CGSize {
        let natural = subview.sizeThatFits(.unspecified)
        return natural.width > width ? subview.sizeThatFits(ProposedViewSize(width: width, height: nil)) : natural
    }

    private func rows(_ subviews: Subviews, width: CGFloat) -> [(indices: [Int], size: CGSize)] {
        var rows: [(indices: [Int], size: CGSize)] = []
        for index in subviews.indices {
            let size = size(of: subviews[index], width: width)
            if let last = rows.last, last.size.width + horizontal + size.width <= width {
                rows[rows.count - 1].indices.append(index)
                rows[rows.count - 1].size.width += horizontal + size.width
                rows[rows.count - 1].size.height = max(last.size.height, size.height)
            } else {
                rows.append(([index], size))
            }
        }
        return rows
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = rows(subviews, width: proposal.width ?? .infinity)
        let height = rows.map(\.size.height).reduce(0, +) + vertical * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: proposal.width ?? rows.map(\.size.width).max() ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = size(of: subviews[index], width: bounds.width)
                subviews[index].place(at: CGPoint(x: x, y: y + (row.size.height - size.height) / 2), proposal: ProposedViewSize(size))
                x += size.width + horizontal
            }
            y += row.size.height + vertical
        }
    }
}

/// One line of the block: what, how much, a bar and what the bar is made of.
struct LoadRow: View {
    var title: String
    var reading: LoadReading
    var segments: [LoadBar.Segment] = []
    var legend: [LoadLegendItem] = []
    var style: LoadRowStyle

    private var spoken: String {
        switch reading {
        case .waiting: return ""
        case .noData: return L("no data")
        case .value(let text): return text
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Text(title)
                    .foregroundStyle(Palette.text2)
                    .lineLimit(1)
                    .frame(width: style.titleWidth, alignment: .leading)
                value
                LoadBar(segments: segments, height: style.barHeight, dashed: reading == .noData)
                    .frame(minWidth: 40)
            }
            .font(.system(size: style.fontSize))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(title)
            .accessibilityValue(spoken)
            if !legend.isEmpty {
                LoadFlowLayout {
                    ForEach(Array(legend.enumerated()), id: \.offset) { _, item in
                        HStack(spacing: 5) {
                            RoundedRectangle(cornerRadius: 2).fill(item.color).frame(width: 8, height: 8)
                            Text(item.text).lineLimit(2)
                        }
                    }
                }
                .font(.system(size: 11.5).monospacedDigit())
                .foregroundStyle(Palette.text2)
                .padding(.leading, style.titleWidth + style.valueWidth + 20)
            }
        }
    }

    @ViewBuilder private var value: some View {
        switch reading {
        case .waiting:
            Text(verbatim: "—")
                .foregroundStyle(Palette.text3)
                .frame(width: style.valueWidth, alignment: .trailing)
        case .noData:
            // Longer than a number in both languages, so it takes the room it needs from the bar.
            Text(L("no data"))
                .italic()
                .foregroundStyle(Palette.text3)
                .lineLimit(1)
                .fixedSize()
                .frame(minWidth: style.valueWidth, alignment: .trailing)
        case .value(let text):
            Text(text)
                .fontWeight(.semibold)
                .monospacedDigit()
                .lineLimit(1)
                .frame(width: style.valueWidth, alignment: .trailing)
        }
    }
}
