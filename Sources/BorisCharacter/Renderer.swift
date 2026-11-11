import CoreGraphics
import Foundation

/// Draws poses into bitmaps. All sizes are in pixels.
public enum Renderer {
    static let fullView = CGRect(x: -22, y: -56, width: 306, height: 306)
    static let simpleView = CGRect(x: -6, y: -14, width: 96, height: 96)
    static let trayView = CGRect(x: 0, y: 0, width: 84, height: 72)
    /// With room for tall hats, a little smaller on the same canvas.
    static let roomyFullView = CGRect(x: -30, y: -64, width: 320, height: 320)
    static let roomySimpleView = CGRect(x: -8, y: -16, width: 100, height: 100)

    /// The menu bar icon's size in points. The extra width is for the cigar.
    public static let iconPoints = CGSize(width: 21, height: 18)

    /// The red alarm dot in icon points. It is a separate layer, because a template image loses its colour.
    public static let alarmDot = (x: CGFloat(18.25), y: CGFloat(2.75), radius: CGFloat(2.25))

    /// What he tilts around in a `roomy` picture, as a share of its width and height from the top left.
    /// A view can turn a picture drawn upright around it, and he leans just as if the lean were drawn.
    public static func leanPivot(simple: Bool) -> CGPoint {
        let view = simple ? roomySimpleView : roomyFullView
        let pivot = simple ? WalrusSimple.pivot : WalrusFull.pivot
        return CGPoint(x: (pivot.x - view.minX) / view.width, y: (pivot.y - view.minY) / view.height)
    }

    public static func image(_ pose: Pose, pixels: Int, roomy: Bool = false) -> CGImage? {
        colour(view: roomy ? roomyFullView : fullView, width: pixels, height: pixels) { WalrusFull(s: $0, crow: pose.crow).draw(pose) }
    }

    public static func image(_ pose: SimplePose, pixels: Int, roomy: Bool = false) -> CGImage? {
        colour(view: roomy ? roomySimpleView : simpleView, width: pixels, height: pixels) { WalrusSimple(s: $0, mono: false, crow: pose.crow).draw(pose) }
    }

    /// Black with alpha, which is what a template image needs. `scale` is 1 or 2: at 1 the drawing drops its finest cuts.
    /// `white` is for a layer on a dark menu bar, where the system does not tint anything.
    public static func template(_ pose: SimplePose, scale: Int, white: Bool = false) -> CGImage? {
        let width = Int(iconPoints.width) * scale
        let height = Int(iconPoints.height) * scale
        guard let mask = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue),
              let out = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        mask.setFillColor(gray: 0, alpha: 1)
        mask.fill(CGRect(x: 0, y: 0, width: width, height: height))
        place(mask, view: trayView, width: width, height: height)
        WalrusSimple(s: Sketch(ctx: mask), mono: true, low: scale == 1).draw(pose)
        guard let from = mask.data, let to = out.data else { return nil }
        // In the mask white stays and black is cut away, so its brightness becomes the alpha.
        let source = from.assumingMemoryBound(to: UInt8.self)
        let target = to.assumingMemoryBound(to: UInt8.self)
        for y in 0..<height {
            for x in 0..<width {
                let alpha = source[y * mask.bytesPerRow + x]
                let pixel = y * out.bytesPerRow + x * 4
                target[pixel + 3] = alpha
                if white {
                    // Premultiplied: full white at this alpha.
                    target[pixel] = alpha
                    target[pixel + 1] = alpha
                    target[pixel + 2] = alpha
                }
            }
        }
        return out.makeImage()
    }

    private static func colour(view: CGRect, width: Int, height: Int, draw: (Sketch) -> Void) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        place(ctx, view: view, width: width, height: height)
        draw(Sketch(ctx: ctx))
        return ctx.makeImage()
    }

    /// Maps the drawing's grid, with y pointing down, onto the bitmap.
    private static func place(_ ctx: CGContext, view: CGRect, width: Int, height: Int) {
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: CGFloat(width) / view.width, y: -CGFloat(height) / view.height)
        ctx.translateBy(x: -view.minX, y: -view.minY)
    }
}
