import BorisCharacter
import BorisCore
import SwiftUI

/// The walrus at any size, built-in or from a pack: a surface never needs to know which.
/// He moves only in the states that may, only while he can be seen. See `WalrusCanvasView`.
struct WalrusView: View {
    enum Style {
        case full, simple
    }

    var pose: PoseName
    var loop: TimeInterval
    var outfit: Outfit
    var size: CGFloat
    var style = Style.full
    /// Keeps moving in a state that is otherwise still, for the preview.
    var loops = false
    /// With a stage he follows the pointer and plays its reactions.
    var stage: WalrusStage?
    var onPoke: (() -> Void)?

    init(mood: Mood, outfit: Outfit, size: CGFloat, style: Style = .full, stage: WalrusStage? = nil, onPoke: (() -> Void)? = nil) {
        pose = PoseName(mood: mood)
        loop = Timeline.loop(for: mood)
        self.outfit = outfit
        self.size = size
        self.style = style
        self.stage = stage
        self.onPoke = onPoke
    }

    init(pose: PoseName, outfit: Outfit, size: CGFloat, style: Style = .full, loops: Bool = false, stage: WalrusStage? = nil, onPoke: (() -> Void)? = nil) {
        self.pose = pose
        loop = Timeline.loop(for: .sleeping)
        self.outfit = outfit
        self.size = size
        self.style = style
        self.loops = loops
        self.stage = stage
        self.onPoke = onPoke
    }

    var body: some View {
        WalrusCanvas(
            look: WalrusCanvasView.Look(
                pose: pose,
                loop: loop,
                outfit: outfit,
                pixels: Int(size * 2),
                simple: style == .simple,
                loops: loops,
                pack: WalrusArt.shared.pack,
                revision: stage?.revision ?? 0,
                upsideDown: stage?.upsideDown ?? false
            ),
            stage: stage,
            onPoke: onPoke
        )
        .frame(width: size, height: size)
        .accessibilityHidden(onPoke == nil)
        .accessibilityLabel(Text(verbatim: "Boris"))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { onPoke?() }
    }
}

private struct WalrusCanvas: NSViewRepresentable {
    var look: WalrusCanvasView.Look
    var stage: WalrusStage?
    var onPoke: (() -> Void)?

    func makeNSView(context: Context) -> WalrusCanvasView {
        WalrusCanvasView()
    }

    func updateNSView(_ view: WalrusCanvasView, context: Context) {
        view.stage = stage
        view.onPoke = onPoke
        view.look = look
    }
}
