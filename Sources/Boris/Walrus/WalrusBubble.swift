import BorisCore
import SwiftUI

extension Palette {
    static let bubble = Color(DesignTokens.bubble)
    static let bubbleBorder = Color(DesignTokens.bubbleBorder)
}

/// A line of the walrus. It lies over the interface and never moves anything aside.
struct WalrusBubble: View {
    enum Tail {
        case left, up
    }

    var text: String
    var count = 1
    var tail = Tail.left
    /// In a stack of lines only the one nearest the walrus points at him.
    var showsTail = true
    var maxWidth: CGFloat = 230

    private var words: some View {
        Text(text)
            .font(.system(size: 12.5))
            .lineSpacing(2)
            .foregroundStyle(Palette.text1)
    }

    var body: some View {
        // A short line gets a bubble of its size, a long one wraps at the width.
        ViewThatFits(in: .horizontal) {
            balloon(words.fixedSize())
            balloon(words.fixedSize(horizontal: false, vertical: true))
        }
        .frame(width: maxWidth, alignment: .leading)
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(L("Boris's line"))
        .accessibilityValue(text)
        // A new line can replace the one on screen without the bubble ever disappearing.
        .onChange(of: text, initial: true) { _, line in AccessibilityNotification.Announcement(line).post() }
    }

    private func balloon(_ content: some View) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            content
            if count > 1 {
                Text(verbatim: "×\(count)")
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Palette.text1)
                    .padding(.horizontal, 6)
                    .frame(height: 16)
                    .background(Capsule().fill(Palette.fill2))
                    .fixedSize()
            }
        }
        .padding(EdgeInsets(top: 7, leading: 11, bottom: 8, trailing: 11))
        .background(alignment: .topLeading) {
            if showsTail {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Palette.bubble)
                    .frame(width: 10, height: 10)
                    .rotationEffect(.degrees(45))
                    .offset(tail == .left ? CGSize(width: -5, height: 16) : CGSize(width: 18, height: -5))
                    .shadow(color: Palette.bubbleBorder, radius: 0.5)
            }
        }
        .background(RoundedRectangle(cornerRadius: 10).fill(Palette.bubble))
        .overlay {
            RoundedRectangle(cornerRadius: 10).strokeBorder(Palette.bubbleBorder, lineWidth: 0.5)
        }
        .overlay {
            // The thin brand line marks a remark of Boris. It is the bubble's own left edge, so it bends with the corners.
            RoundedRectangle(cornerRadius: 10)
                .fill(Palette.brandGold)
                .mask(alignment: .leading) { Rectangle().frame(width: 2.5) }
        }
        .shadow(color: .black.opacity(0.26), radius: 11, y: 8)
    }
}

/// Shows what the walrus says right now, wherever a surface puts it: one line under another, each leaving on its own time.
struct WalrusLineOverlay: View {
    var stage: WalrusStage
    var tail = WalrusBubble.Tail.left
    var maxWidth: CGFloat = 230

    var body: some View {
        let lines = stage.lines
        // Beside the walrus the stack grows up from the bottom, so the newest line is the one nearest him; under him the oldest is.
        let pointing = tail == .left ? lines.last?.id : lines.first?.id
        VStack(alignment: .leading, spacing: 6) {
            ForEach(lines) { shown in
                WalrusBubble(text: shown.line.text, count: shown.line.count, tail: tail, showsTail: shown.id == pointing, maxWidth: maxWidth)
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .offset(y: 8)),
                        removal: .opacity.combined(with: .offset(y: -18))
                    ))
            }
        }
        .animation(.easeOut(duration: 0.4), value: lines.map(\.id))
    }
}
