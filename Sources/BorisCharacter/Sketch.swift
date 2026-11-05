import CoreGraphics
import CoreText
import Foundation

struct Ink: Sendable, Equatable {
    let red, green, blue, alpha: CGFloat

    init(_ hex: UInt32, alpha: CGFloat = 1) {
        red = CGFloat((hex >> 16) & 255) / 255
        green = CGFloat((hex >> 8) & 255) / 255
        blue = CGFloat(hex & 255) / 255
        self.alpha = alpha
    }

    private init(red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    func opacity(_ value: CGFloat) -> Ink {
        Ink(red: red, green: green, blue: blue, alpha: value)
    }

    var color: CGColor { CGColor(srgbRed: red, green: green, blue: blue, alpha: alpha) }

    static let white = Ink(0xFFFFFF)
    static let black = Ink(0x000000)
}

/// SVG's painting rules on a `CGContext` whose y axis points down: fill first, then stroke.
struct Sketch {
    let ctx: CGContext

    func group(_ body: () -> Void) {
        ctx.saveGState()
        body()
        ctx.restoreGState()
    }

    func translate(_ x: CGFloat, _ y: CGFloat) {
        ctx.translateBy(x: x, y: y)
    }

    func scale(_ x: CGFloat, _ y: CGFloat) {
        ctx.scaleBy(x: x, y: y)
    }

    func rotate(_ degrees: CGFloat) {
        ctx.rotate(by: degrees * .pi / 180)
    }

    func rotate(_ degrees: CGFloat, around x: CGFloat, _ y: CGFloat) {
        translate(x, y)
        rotate(degrees)
        translate(-x, -y)
    }

    func paint(_ path: CGPath, fill: Ink?, stroke: Ink? = nil, width: CGFloat = 0, cap: CGLineCap = .butt, join: CGLineJoin = .round) {
        if let fill {
            ctx.addPath(path)
            ctx.setFillColor(fill.color)
            ctx.fillPath()
        }
        if let stroke {
            ctx.addPath(path)
            ctx.setStrokeColor(stroke.color)
            ctx.setLineWidth(width)
            ctx.setLineCap(cap)
            ctx.setLineJoin(join)
            ctx.setMiterLimit(4)
            ctx.strokePath()
        }
    }

    /// A filled part with an outline and round corners.
    func shape(_ d: String, fill: Ink?, stroke: Ink? = nil, width: CGFloat = 0) {
        paint(SVGPath.path(d), fill: fill, stroke: stroke, width: width)
    }

    /// A round-ended line with no fill.
    func line(_ d: String, _ color: Ink, _ width: CGFloat) {
        paint(SVGPath.path(d), fill: nil, stroke: color, width: width, cap: .round)
    }

    /// A butt-ended line with sharp corners, SVG's default stroke.
    func plain(_ d: String, _ color: Ink, _ width: CGFloat) {
        paint(SVGPath.path(d), fill: nil, stroke: color, width: width, join: .miter)
    }

    func circle(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat, fill: Ink?, stroke: Ink? = nil, width: CGFloat = 0) {
        ellipse(x, y, r, r, fill: fill, stroke: stroke, width: width)
    }

    func ellipse(_ x: CGFloat, _ y: CGFloat, _ rx: CGFloat, _ ry: CGFloat, fill: Ink?, stroke: Ink? = nil, width: CGFloat = 0) {
        paint(CGPath(ellipseIn: CGRect(x: x - rx, y: y - ry, width: 2 * rx, height: 2 * ry), transform: nil), fill: fill, stroke: stroke, width: width, join: .miter)
    }

    func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, corner: CGFloat = 0, fill: Ink?, stroke: Ink? = nil, width: CGFloat = 0) {
        let box = CGRect(x: x, y: y, width: w, height: h)
        let path = corner > 0 ? CGPath(roundedRect: box, cornerWidth: min(corner, w / 2), cornerHeight: min(corner, h / 2), transform: nil) : CGPath(rect: box, transform: nil)
        paint(path, fill: fill, stroke: stroke, width: width, join: .miter)
    }

    /// A soft coloured halo around everything drawn in `body`. `radius` is in the drawing's own units.
    func glow(_ radius: CGFloat?, _ body: () -> Void) {
        guard let radius else {
            body()
            return
        }
        group {
            // Shadow blur ignores the transform, so it is scaled by hand. Twice the radius matches SVG's drop-shadow.
            ctx.setShadow(offset: .zero, blur: 2 * radius * abs(ctx.ctm.a), color: Ink(0x6DFFC0).color)
            ctx.beginTransparencyLayer(auxiliaryInfo: nil)
            body()
            ctx.endTransparencyLayer()
        }
    }

    func clipped(_ path: CGPath, _ body: () -> Void) {
        group {
            ctx.addPath(path)
            ctx.clip()
            body()
        }
    }

    func clippedToCircle(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat, _ body: () -> Void) {
        clipped(CGPath(ellipseIn: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r), transform: nil), body)
    }

    /// One bold glyph, outlined first so the outline does not eat into it.
    func glyph(_ text: String, x: CGFloat, y: CGFloat, size: CGFloat, fill: Ink, stroke: Ink, width: CGFloat) {
        let font = CTFontCreateWithName("HelveticaNeue-Bold" as CFString, size, nil)
        var characters = Array(text.utf16)
        var glyphs = [CGGlyph](repeating: 0, count: characters.count)
        guard CTFontGetGlyphsForCharacters(font, &characters, &glyphs, characters.count), let first = glyphs.first else { return }
        var place = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: x, ty: y)
        guard let path = CTFontCreatePathForGlyph(font, first, &place) else { return }
        paint(path, fill: nil, stroke: stroke, width: width)
        paint(path, fill: fill)
    }
}
