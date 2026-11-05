import BorisCharacter
import BorisCore
import SwiftUI

/// The walrus at any size. A picture is drawn once and kept.
struct WalrusView: View {
    enum Style {
        case full, simple
    }

    private struct Key: Hashable {
        let pose: PoseName
        let outfit: Outfit
        let pixels: Int
        let style: Int
    }

    @MainActor private static var pictures: [Key: CGImage] = [:]

    var mood: Mood
    var outfit: Outfit
    var size: CGFloat
    var style = Style.full

    var body: some View {
        Group {
            if let picture {
                Image(decorative: picture, scale: 2)
                    .resizable()
                    .interpolation(.high)
            } else {
                Color.clear
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private var picture: CGImage? {
        let pose = PoseName(mood: mood)
        let key = Key(pose: pose, outfit: outfit, pixels: Int(size * 2), style: style == .full ? 0 : 1)
        if let known = Self.pictures[key] { return known }
        let made: CGImage?
        switch style {
        case .full:
            made = Renderer.image(Dress.apply(outfit, to: Timeline.full(pose, t: pose.keyTime)), pixels: key.pixels, roomy: true)
        case .simple:
            made = Renderer.image(Dress.apply(outfit, to: Timeline.simple(pose, t: pose.keyTime, mono: false), mono: false), pixels: key.pixels, roomy: true)
        }
        Self.pictures[key] = made
        return made
    }
}
