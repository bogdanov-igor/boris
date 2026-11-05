import CoreGraphics
import Foundation

/// The simplified drawing on an 84x72 grid, in colour or as a one-colour menu bar icon.
/// In the menu bar a unit is half a pixel at 2x, so 4 units are 1 point. Cuts never go below 3 units.
/// Source: `design/tools/walrus/simple.py`.
struct WalrusSimple {
    private static let outline = Ink(0x2E1C17)
    private static let hatInk = Ink(0x2F2E44), band = Ink(0xB3313F), gold = Ink(0xF4C542), ink = Ink(0x231814)
    private static let cigarInk = Ink(0x7A4A28), jawInk = Ink(0x8A5539), ember = Ink(0xFF7A2A), ash = Ink(0xCFCBC4)
    private static let edge: CGFloat = 2.8
    private static let cut: CGFloat = 3
    private static let cigars: [Cigar: (x0: CGFloat, y0: CGFloat, x1: CGFloat, y1: CGFloat)] = [.flat: (36, 49, 77, 56), .up: (36, 49, 76, 36), .droop: (36, 49, 60, 69)]
    private static let leftX: CGFloat = 19, rightX: CGFloat = 41.5, eyeY: CGFloat = 27.5

    let s: Sketch
    /// In one colour white stays and black is cut away.
    let mono: Bool
    /// The variant for 1x screens: no pupils, band or upper moustache line.
    var low = false
    /// Friday the 13th. In the menu bar nothing changes: one colour cannot go darker.
    var crow = false

    private var hide: Ink { crow && !mono ? Ink(0x1F1C30) : Ink(0xA9704F) }
    private var stache: Ink { crow && !mono ? Ink(0xD4FFEC) : Ink(0xF7EAD3) }
    private var tuskInk: Ink { crow && !mono ? Ink(0xE8FFF5) : Ink(0xFFF9EC) }

    private func paint(_ color: Ink) -> Ink { mono ? .white : color }
    private var stroke: Ink { mono ? .black : Self.outline }
    private var strokeWidth: CGFloat { mono ? Self.cut : Self.edge }

    func draw(_ pose: SimplePose) {
        s.glow(crow && !mono ? 2 : nil) { drawPose(pose) }
    }

    private func drawPose(_ pose: SimplePose) {
        s.group {
            s.translate(0, pose.bob)
            s.rotate(pose.tilt, around: 30, 38)
            if let kind = pose.cigar { cigar(kind) }
            jaw(pose.jaw)
            tusks(apart: pose.jaw > 0.3)
            head()
            if pose.cigar == .fish, !mono {
                fish()
                tusks(apart: false)
            }
            leftEye(pose.eyeLeft, look: pose.look, ring: pose.ring)
            rightEye(pose.eyeRight, look: pose.look)
            if mono {
                monoMoustache(smile: pose.smile, lift: pose.lift)
            } else {
                moustache(smile: pose.smile, lift: pose.lift)
            }
            nose(lift: pose.lift)
            if pose.glasses { pixelGlasses() }
            if let wear = pose.headwear, wear != .flower {
                headwear(wear, pose.hat)
            } else {
                hat(pose.hat)
            }
            if pose.headwear == .flower { flower(pose.hat) }
            if let kind = pose.cigar, let at = Self.cigars[kind], let smoke = pose.smoke {
                puffs(phase: smoke, x: at.x1, y: at.y1)
            }
        }
        if pose.popped, !mono {
            s.paint(SVGPath.path("M8 46L7 56"), fill: nil, stroke: Self.outline, width: 3.2, cap: .round)
            s.paint(SVGPath.path("M8 46L7 56"), fill: nil, stroke: Self.gold, width: 1.5, cap: .round)
            s.circle(7, 62, 5, fill: Ink(0xE8F5F9), stroke: Self.outline, width: 3 + Self.edge)
            s.circle(7, 62, 5, fill: nil, stroke: Self.gold, width: 3)
        }
    }

    private func part(_ d: String, _ color: Ink, edged: Bool = true) {
        s.shape(d, fill: paint(color), stroke: edged ? stroke : nil, width: strokeWidth)
    }

    private func cigar(_ kind: Cigar) {
        guard let at = Self.cigars[kind] else { return }
        let d = "M\(at.x0) \(at.y0)L\(at.x1) \(at.y1)"
        if !mono { s.plain(d, Self.outline, 7.4 + Self.edge) }
        s.plain(d, paint(Self.cigarInk), 7.4)
        let a = at.x1 - at.x0, b = at.y1 - at.y0
        let length = (a * a + b * b).squareRoot()
        let ux = a / length, uy = b / length
        func stretch(_ from: CGFloat, _ to: CGFloat) -> String {
            "M\(at.x1 - ux * from) \(at.y1 - uy * from)L\(at.x1 - ux * to) \(at.y1 - uy * to)"
        }
        if mono {
            // A hairline break before the tip reads as the ember.
            s.plain(stretch(6, 3.4), .black, 8)
        } else {
            s.plain(stretch(8, 3), kind == .droop ? Ink(0x6E6A64) : Self.ember, 7.4)
            s.plain(stretch(3, 0), Self.ash, 7.4)
        }
    }

    private func jaw(_ open: CGFloat) {
        let b = 60 + 9 * open
        if !mono || open > 0 {
            part("M21 50C21 \(b) 26 \(b + 2) 30 \(b + 2)C34 \(b + 2) 39 \(b) 39 50Z", Self.jawInk)
        }
        guard open > 0 else { return }
        s.ellipse(30, 54 + 4 * open, 5.4, 3.8 + 3.8 * open, fill: mono ? .black : Ink(0x3A1418))
        if !mono { s.ellipse(30, 57 + 6 * open, 4.4, 2.4, fill: Ink(0xE8667A)) }
    }

    private func tusks(apart: Bool) {
        let edged = !mono || apart
        part("M13 49C13 59 17 67 22.6 71.4C26.6 66 28.4 59 28.4 49Z", tuskInk, edged: edged)
        part("M32.6 49C32.6 54 33.4 57 34.6 59.6L46 58.4C46.8 56 46.8 52 46 49Z", tuskInk, edged: edged)
        // The chipped tusk, with its gold crown: visibly shorter, even in one colour.
        part("M34.6 59.6L46 58.4C46 61.4 43.6 64.4 40.2 66C37.4 64.6 35 62.2 34.6 59.6Z", Self.gold, edged: !mono)
    }

    private func head() {
        part("M30 10C44 10 50 18 52 28C53 35 58 41 57 46C56 52.6 46 54 30 54C14 54 4 52.6 3 46C2 41 7 35 8 28C10 18 16 10 30 10Z", hide, edged: !mono)
    }

    private func leftEye(_ kind: Eye, look: CGPoint, ring: Bool) {
        let x = Self.leftX, y = Self.eyeY
        let hole: Ink = mono ? .black : .white
        // Pupils are cut away on 1x screens: there they only turn the eye into a smudge.
        let pupilInk: Ink = mono ? (low ? .black : .white) : Self.ink
        let r: CGFloat = mono ? 7.8 : 6.4

        func frame() {
            guard ring, !mono else { return }
            s.circle(x, y, 7.2, fill: nil, stroke: Self.outline, width: 3 + Self.edge)
            s.circle(x, y, 7.2, fill: nil, stroke: Self.gold, width: 3)
        }

        switch kind {
        case .open, .tired, .wide, .small:
            let radius: CGFloat = kind == .wide ? r + 1.4 : kind == .small ? r - 2 : r
            let pupil: CGFloat = kind == .open ? 3.8 : kind == .tired ? 3.4 : kind == .wide ? 2.1 : 2.8
            if !mono, !ring || kind == .small { s.circle(x, y, radius + Self.edge / 2, fill: Self.outline) }
            s.circle(x, y, radius, fill: hole)
            if kind == .tired, mono {
                // Half moon only: a pupil here turns into a moustache at 18 points.
                s.shape("M\(x - 11) \(y - 11)H\(x + 11)V\(y + 0.5)H\(x - 11)Z", fill: .white)
            } else {
                s.circle(x + look.x, y + look.y, pupil, fill: pupilInk)
                if !mono, kind != .wide { s.circle(x + look.x - 1.3, y + look.y - 1.4, 1.05, fill: .white) }
                if kind == .tired {
                    s.clippedToCircle(x, y, radius) {
                        s.shape("M\(x - 11) \(y - 11)H\(x + 11)V\(y)H\(x - 11)Z", fill: hide)
                    }
                    s.plain("M\(x - radius) \(y)H\(x + radius)", Self.outline, 2.2)
                }
            }
            if kind == .open || kind == .tired { frame() }
        case .closed:
            if !mono { s.circle(x, y, r, fill: Ink(0xC28A66)) }
            cutLine("M\(x - 5.2) \(y - 1)C\(x - 2.4) \(y + 3.4) \(x + 2.4) \(y + 3.4) \(x + 5.2) \(y - 1)", 3)
            frame()
        case .happy:
            if !mono { s.circle(x, y, r, fill: .white) }
            cutLine("M\(x - 5) \(y + 2.6)C\(x - 2.4) \(y - 4.4) \(x + 2.4) \(y - 4.4) \(x + 5) \(y + 2.6)", 3.2)
            frame()
        case .dizzy:
            if !mono {
                s.circle(x, y, r + Self.edge / 2, fill: Self.outline)
                s.circle(x, y, r, fill: .white)
            }
            cutLine("M\(x - 4.2) \(y - 4.2)L\(x + 4.2) \(y + 4.2)M\(x + 4.2) \(y - 4.2)L\(x - 4.2) \(y + 4.2)", 3.1)
        case .heart:
            heartEye(x, r)
        case .lid, .big, .squint:
            break
        }
    }

    private func rightEye(_ kind: Eye, look: CGPoint) {
        let x = Self.rightX, y = Self.eyeY
        let hole: Ink = mono ? .black : .white
        let pupilInk: Ink = mono ? (low ? .black : .white) : Self.ink
        let r: CGFloat = 6.4

        func socket(_ radius: CGFloat, _ fill: Ink) {
            s.circle(x, y, radius + Self.edge / 2, fill: Self.outline)
            s.circle(x, y, radius, fill: fill)
        }

        switch kind {
        case .lid:
            if mono {
                // One slanted half-moon: all of his contempt, in a few pixels.
                s.shape("M\(x - 6.6) \(y + 2.6)L\(x + 6.6) \(y - 1.4)C\(x + 7) \(y + 3) \(x + 4) \(y + 6.4) \(x) \(y + 6.4)C\(x - 3.6) \(y + 6.4) \(x - 6.4) \(y + 5) \(x - 6.6) \(y + 2.6)Z", fill: .black)
                return
            }
            socket(r, .white)
            s.circle(x + look.x, y + 1.2 + look.y, 3.3, fill: Self.ink)
            s.clippedToCircle(x, y, r) {
                s.shape("M\(x - 9) \(y - 9)H\(x + 9)V\(y - 2)L\(x - 9) \(y + 1.4)Z", fill: hide)
            }
            s.plain("M\(x - r) \(y + 1)L\(x + r) \(y - 1.6)", Self.outline, 2.4)
        case .open, .wide, .small, .big:
            let radius: CGFloat = kind == .open ? r + (mono ? 0.6 : 0) : kind == .wide ? r + 2.4 : kind == .small ? r - 1.8 : r + 1.2
            let pupil: CGFloat = kind == .open ? 3.2 : kind == .wide ? 2.1 : kind == .small ? 2.4 : 3.6
            if !mono { s.circle(x, y, radius + Self.edge / 2, fill: Self.outline) }
            s.circle(x, y, radius, fill: hole)
            s.circle(x + look.x, y + look.y, pupil, fill: pupilInk)
            if !mono, kind != .wide { s.circle(x + look.x - 1.1, y + look.y - 1.2, 0.95, fill: .white) }
        case .tired:
            if mono {
                s.shape("M\(x - 6.6) \(y + 0.4)H\(x + 6.6)C\(x + 6) \(y + 7) \(x - 6) \(y + 7) \(x - 6.6) \(y + 0.4)Z", fill: .black)
                return
            }
            socket(r, .white)
            s.circle(x + look.x, y + look.y, 3, fill: Self.ink)
            s.clippedToCircle(x, y, r) {
                s.shape("M\(x - 9) \(y - 9)H\(x + 9)V\(y)H\(x - 9)Z", fill: hide)
            }
            s.plain("M\(x - r) \(y)H\(x + r)", Self.outline, 2.2)
        case .closed:
            if !mono { socket(r, Ink(0xC28A66)) }
            cutLine("M\(x - 5) \(y - 1)C\(x - 2.4) \(y + 3.4) \(x + 2.4) \(y + 3.4) \(x + 5) \(y - 1)", 3)
        case .happy:
            if !mono { socket(r, .white) }
            cutLine("M\(x - 4.8) \(y + 2.6)C\(x - 2.4) \(y - 4.4) \(x + 2.4) \(y - 4.4) \(x + 4.8) \(y + 2.6)", 3.2)
        case .dizzy:
            if !mono { socket(r, .white) }
            cutLine("M\(x - 3.9) \(y - 3.9)L\(x + 3.9) \(y + 3.9)M\(x + 3.9) \(y - 3.9)L\(x - 3.9) \(y + 3.9)", 3.1)
        case .heart:
            heartEye(x, r)
        case .squint:
            break
        }
    }

    private func heartEye(_ x: CGFloat, _ r: CGFloat) {
        let y = Self.eyeY
        let h = mono ? r * 1.28 : r * 0.92
        let d = "M\(x) \(y + h * 0.86)C\(x - h * 1.3) \(y) \(x - h * 0.6) \(y - h) \(x) \(y - h * 0.22)C\(x + h * 0.6) \(y - h) \(x + h * 1.3) \(y) \(x) \(y + h * 0.86)Z"
        if mono {
            s.shape(d, fill: .black)
        } else {
            s.circle(x, y, r + Self.edge / 2, fill: Self.outline)
            s.circle(x, y, r, fill: .white)
            s.shape(d, fill: Ink(0xE5383B))
        }
    }

    private func cutLine(_ d: String, _ width: CGFloat) {
        s.line(d, mono ? .black : Self.ink, width)
    }

    private func moustacheSide(right: Bool, smile: CGFloat, lift: CGFloat, _ body: () -> Void) {
        s.group {
            s.translate(right ? 60 : 0, lift)
            if right { s.scale(-1, 1) }
            s.rotate(smile * 13, around: 30, 40)
            body()
        }
    }

    private func monoMoustache(smile: CGFloat, lift: CGFloat) {
        let width: CGFloat = low ? 4 : 3
        if !low {
            for right in [false, true] {
                moustacheSide(right: right, smile: smile, lift: lift) {
                    s.line("M25 37.4C19 34.4 12 36 8 43.6", .black, width)
                }
            }
        }
        s.line("M30 \(41 + lift)V\(49.6 + lift)", .black, width)
    }

    private func moustache(smile: CGFloat, lift: CGFloat) {
        for right in [false, true] {
            moustacheSide(right: right, smile: smile, lift: lift) {
                s.shape("M30 38C24 33.6 11 34.6 6 43C4 49 10 54.8 18 54.8C24 54.8 28 52 30 47.6Z", fill: stache, stroke: Self.outline, width: Self.edge)
            }
        }
    }

    private func nose(lift: CGFloat) {
        s.ellipse(30, 38.4 + lift, 6, 3.9, fill: mono ? .black : Self.ink)
        if !mono { s.ellipse(27.8, 37 + lift, 2, 1, fill: Ink.white.opacity(0.75)) }
    }

    /// Deliberately one size too small: it sits on top of the dome and leaves the face alone.
    private func hat(_ hat: Hat) {
        s.group {
            s.translate(hat.x, hat.y)
            s.rotate(hat.tilt, around: 30, 14)
            part("M7 11.6C14 17.6 46 17.6 53 11.6C53 16.4 42 20 30 20C18 20 7 16.4 7 11.6Z", Self.hatInk)
            part("M16 14C14 3.4 22 0 30 0C38 0 46 3.4 44 14C36 16.6 24 16.6 16 14Z", Self.hatInk, edged: !mono)
            if mono {
                if !low { s.plain("M15.6 9.4C24 12 36 12 44.4 9.4", .black, 3) }
            } else {
                s.shape("M15.4 8.4C24 11.2 36 11.2 44.6 8.4L44 14C36 16.6 24 16.6 16 14Z", fill: Self.band, stroke: Self.outline, width: 1.6)
            }
        }
    }

    /// Date hats replace the bowler. In the menu bar they are plain silhouettes with one cut line.
    private func headwear(_ kind: Headwear, _ hat: Hat) {
        func ball(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat, _ color: Ink) {
            s.circle(x, y, r, fill: paint(color), stroke: stroke, width: strokeWidth)
        }
        s.group {
            s.translate(hat.x, hat.y)
            s.rotate(hat.tilt, around: 30, 14)
            switch kind {
            case .santa:
                part("M10 16C12 4 24 1 38 2C48 3 56 8 60 16C54 12 50 12 48 16Z", Ink(0xD23340))
                part("M6 13C16 18 44 18 54 13C56 15 56 19 54 20C44 24 16 24 6 20C4 19 4 15 6 13Z", Ink(0xFFF6EE))
                ball(63, 18, 4.6, Ink(0xFFF6EE))
            case .witch:
                part("M0 15C14 11 46 11 60 15C46 21 14 21 0 15Z", Ink(0x3A2A5E))
                part("M18 14C22 8 28 3 36 0C36 3 36 4 38 6C40 8 41 11 42 14C36 16 24 16 18 14Z", Ink(0x3A2A5E))
                if !mono { s.shape("M18.6 11.4C24 13.4 36 13.4 41.4 11.4L42 14C36 16 24 16 18 14Z", fill: Ink(0xF05D23)) }
            case .party:
                part("M17 17L30 3L43 17C36 20 24 20 17 17Z", Ink(0x4CC9F0))
                if mono {
                    s.plain("M22 11.6C27 13 33 13 38 11.6", .black, 2.6)
                } else {
                    s.shape("M22.4 11.4C27 13 33 13 37.6 11.4L39.6 13.6C33 15.6 27 15.6 20.4 13.6Z", fill: .white)
                }
                ball(30, 3, 3.6, Ink(0xF72585))
            case .scholar:
                part("M15 13H45V19C37 23 23 23 15 19Z", Ink(0x23233A))
                part("M30 2L60 10L30 18L1 10Z", Self.hatInk)
                if mono {
                    s.plain("M30 10L54 13V24", .black, 4.6)
                    s.paint(SVGPath.path("M54 14V26"), fill: nil, stroke: .white, width: 3, cap: .round)
                } else {
                    s.line("M30 10L54 13V24", Self.gold, 2.4)
                    s.shape("M51.6 23H56.4L57 29H51Z", fill: Self.gold)
                }
            case .nightcap:
                part("M10 16C10 5 22 1 34 2C46 3 56 12 60 28C54 24 48 20 44 16Z", Ink(0x6C7BC9))
                part("M6 13C16 18 44 18 52 13C54 15 54 19 52 20C44 23 16 23 6 20C4 19 4 15 6 13Z", Ink(0xE6E9F8))
                ball(61, 31, 4.2, Ink(0xE6E9F8))
            case .flower:
                break
            }
        }
    }

    private func flower(_ hat: Hat) {
        s.group {
            s.translate(hat.x, hat.y)
            s.rotate(hat.tilt, around: 30, 14)
            if mono {
                s.circle(21, 10.4, 5, fill: .black)
                s.circle(21, 10.4, 2, fill: .white)
            } else {
                for degrees in stride(from: CGFloat(0), to: 360, by: 72) {
                    let a = (degrees - 90) * .pi / 180
                    s.circle(21 + 3.1 * cos(a), 10.4 + 3.1 * sin(a), 2.7, fill: Ink(0xFF8FB8))
                }
                s.circle(21, 10.4, 1.9, fill: Self.gold)
            }
        }
    }

    private func pixelGlasses() {
        let d = "M6 21H54V25H51V30H49V33H34V30H32V26H28V30H26V33H11V30H9V25H6Z"
        if mono {
            s.shape(d, fill: .black)
            s.rect(13, 23.4, 5, 3, fill: .white)
            s.rect(36, 23.4, 5, 3, fill: .white)
        } else {
            s.shape(d, fill: Ink(0x0E0D12), stroke: Self.outline, width: 1.6)
            for (x, w) in [(13, 6), (21, 2.6), (36, 6), (44, 2.6)] as [(CGFloat, CGFloat)] {
                s.rect(x, 23.4, w, 2.6, fill: .white)
            }
        }
    }

    private func fish() {
        s.shape("M12 52L1 43C3.6 49 3.6 56 1 62Z", fill: Ink(0x5E93B8), stroke: Self.outline, width: Self.edge)
        s.shape("M10 52C20 42 60 41 78 51C81 53 81 56 78 58C60 66 20 65 10 52Z", fill: Ink(0x7FB3D5), stroke: Self.outline, width: Self.edge)
        s.circle(72, 51, 3, fill: .white, stroke: Self.outline, width: 1.5)
    }

    private func puffs(phase: CGFloat, x: CGFloat, y: CGFloat) {
        for k in 0..<2 {
            let f = (phase + CGFloat(k) / 2).truncatingRemainder(dividingBy: 1)
            let r = 1.8 + f * 2.4
            let cy = y - 6 - f * 24
            if mono, cy - r < 0 { continue }
            s.circle(x + sin(f * 6.3) * 1.6, cy, r, fill: mono ? .white : Ink(0xB4B1C2, alpha: 1 - f * 0.7))
        }
    }
}
