import BorisCore
import SwiftUI

/// The walrus at the bottom of the sidebar, with how things stand in his words. On a low window he shrinks, so he does not push out the pages.
struct SidebarWalrus: View {
    @Bindable var model: AppModel
    var openAbout: () -> Void

    @State private var low = false

    /// What is below him: the mode switch and the margins.
    private static let below: CGFloat = 46

    var body: some View {
        VStack(spacing: 6) {
            WalrusView(mood: model.mood, outfit: model.outfit, size: low ? 96 : 190, stage: model.walrus) {
                if model.pokeWalrus() { openAbout() }
            }
            Text(WalrusLines.standing(mood: model.mood, waiting: model.requestCount))
                .font(.system(size: 12))
                .foregroundStyle(Palette.text2)
                .multilineTextAlignment(.center)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity)
        .background(GeometryReader { proxy in
            Color.clear.onChange(of: proxy.frame(in: .global).maxY, initial: true) { _, bottom in
                low = bottom + Self.below < 700
            }
        })
    }
}
