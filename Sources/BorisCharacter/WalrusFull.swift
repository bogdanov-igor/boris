import CoreGraphics
import Foundation

/// The full drawing: flat vector, one part per function. Source: `design/tools/walrus/walrus.py`.
struct WalrusFull {
    private static let outline = Ink(0x2E1C17)
    private static let hatInk = Ink(0x2F2E44), hatLight = Ink(0x5D5D85)
    private static let band = Ink(0xB3313F), gold = Ink(0xF4C542), goldDark = Ink(0xB98A1F), goldLight = Ink(0xFFE99A)
    private static let ink = Ink(0x231814)
    private static let edge: CGFloat = 6
    private static let cigars: [Cigar: (x: CGFloat, y: CGFloat, rotation: CGFloat)] = [.flat: (128, 156, 10), .up: (128, 156, -16), .droop: (128, 156, 36)]

    let s: Sketch
    private let hide, hideDark, hideLight, stache, stacheDark, tusk, tuskDark: Ink

    init(s: Sketch, crow: Bool = false) {
        self.s = s
        hide = crow ? Ink(0x1F1C30) : Ink(0xA9704F)
        hideDark = crow ? Ink(0x141225) : Ink(0x8A5539)
        hideLight = crow ? Ink(0x3A3658) : Ink(0xC28A66)
        stache = crow ? Ink(0xD4FFEC) : Ink(0xF7EAD3)
        stacheDark = crow ? Ink(0x9DE8C8) : Ink(0xE0CBA7)
        tusk = crow ? Ink(0xE8FFF5) : Ink(0xFFF9EC)
        tuskDark = crow ? Ink(0xB4EFD6) : Ink(0xE6D5B2)
    }

    func draw(_ pose: Pose) {
        s.group {
            if pose.upsideDown { s.rotate(180, around: 120, 128) }
            s.glow(pose.crow ? 7 : nil) {
                if pose.back {
                    drawBack(pose)
                } else {
                    drawFront(pose)
                }
            }
        }
    }

    private func drawFront(_ pose: Pose) {
        s.group {
            s.translate(0, pose.bob)
            s.rotate(pose.tilt, around: 120, 130)
            s.translate(120, 232)
            s.scale(pose.squash.width, pose.squash.height)
            s.translate(-120, -232)
            head()
            s.group {
                if pose.turn != 0 {
                    // A three-quarter view: the whole face slides round the head and narrows a little.
                    s.translate(120 + 30 * pose.turn, 0)
                    s.scale(1 - 0.2 * abs(pose.turn), 1)
                    s.translate(-120, 0)
                }
                if pose.monocle == .worn, pose.turn == 0 { chain(62, 106, 48, 136, sag: 2) }
                jaw(pose.jaw)
                if let kind = pose.cigar, let at = Self.cigars[kind] {
                    cigar(at.x, at.y + pose.lift, at.rotation, lit: pose.lit)
                }
                if pose.cigar == .fish { fish() }
                s.group {
                    s.translate(0, pose.lift)
                    tusks()
                }
                moustache(smile: pose.smile, lift: pose.lift)
                nose(lift: pose.lift)
                eye(80, 88, pose.eyeLeft, look: pose.look, big: true)
                eye(158, 90, pose.eyeRight, look: pose.look, big: false)
                if pose.monocle == .worn { monocle(80, 88, 24) }
                brow(80, 56, side: -1, pose.browLeft)
                brow(158, 66, side: 1, pose.browRight)
                if pose.monocle == .pixel { pixelGlasses() }
            }
            wornOnHead(pose, bowlerAt: Hat(pose.hat.x + 12 * pose.turn, pose.hat.y, pose.hat.tilt))
            if let kind = pose.cigar, let at = Self.cigars[kind], let smoke = pose.smoke {
                let angle = at.rotation * .pi / 180
                puffs(at.x + 120 * cos(angle), at.y + pose.lift + 120 * sin(angle) - 8, phase: smoke)
            }
        }
        if pose.monocle == .popped {
            // Shock pops the monocle out, and it swings on its chain.
            let x = 30 + pose.swing * 14
            chain(50, 150, x, 184, sag: 2)
            monocle(x, 200, 16)
        }
        if let dropped = pose.droppedCigar {
            cigar(dropped.x, dropped.y, dropped.tilt, lit: true, length: 64, thickness: 13)
        }
        pose.effects.forEach(effect)
    }

    /// The same hat from any side, whichever outfit he has on.
    private func wornOnHead(_ pose: Pose, bowlerAt bowlerHat: Hat) {
        switch pose.headwear {
        case .flower?:
            bowler(pose.hat, flower: true)
        case let kind?:
            headwear(kind, pose.hat)
        case nil:
            bowler(bowlerHat)
        }
    }

    /// He has turned his back on you. What he has in his mouth still pokes out: the cigar lies flat from here, and the fish shows on both sides.
    private func drawBack(_ pose: Pose) {
        let at = pose.cigar == .fish ? nil : pose.cigar.flatMap { _ in Self.cigars[.flat] }
        s.group {
            s.translate(0, pose.bob)
            if let at { cigar(at.x, at.y, at.rotation, lit: pose.lit) }
            if pose.cigar == .fish { fish() }
            moustache(smile: 0, lift: 0)
            tusks()
            let d = "M120 26C166 26 192 62 198 104C201 128 208 150 192 162C168 180 72 180 48 162C32 150 39 128 42 104C48 62 74 26 120 26Z"
            outlined(d, hide)
            s.clipped(SVGPath.path(d)) {
                s.shape("M198 60C206 110 206 150 180 184L240 184L240 40Z", fill: hideDark)
            }
            for fold in ["M72 112C96 124 144 124 168 112", "M64 138C92 152 148 152 176 138", "M84 88C102 96 138 96 156 88"] {
                s.line(fold, hideDark, 6)
            }
            wornOnHead(pose, bowlerAt: pose.hat)
            if let at, let smoke = pose.smoke {
                let angle = at.rotation * .pi / 180
                puffs(at.x + 120 * cos(angle), at.y + 120 * sin(angle) - 8, phase: smoke)
            }
        }
    }

    private func outlined(_ d: String, _ fill: Ink) {
        s.shape(d, fill: fill, stroke: Self.outline, width: Self.edge)
    }

    private func head() {
        let d = "M120 26C166 26 192 62 198 104C201 128 208 150 192 162C168 176 72 176 48 162C32 150 39 128 42 104C48 62 74 26 120 26Z"
        outlined(d, hide)
        s.clipped(SVGPath.path(d)) {
            s.shape("M198 60C206 110 206 150 180 180L240 180L240 40Z", fill: hideDark)
            s.line("M70 62C80 46 98 38 116 36", hideLight, 9)
        }
        // Forehead folds: an old, thick hide.
        s.line("M100 74C112 80 128 80 140 74", hideDark, 5)
        s.line("M108 86C114 89 126 89 132 86", hideDark, 4.5)
    }

    /// The lower jaw sits behind the tusks and under the moustache.
    private func jaw(_ open: CGFloat) {
        let b = 186 + 40 * open
        outlined("M90 150C88 172 100 \(b) 120 \(b)C140 \(b) 152 172 150 150Z", hideDark)
        guard open > 0 else { return }
        let inner = b - 9
        let k = min(1, open * 1.4)
        s.shape("M96 150C95 170 106 \(inner) 120 \(inner)C134 \(inner) 145 170 144 150Z", fill: Ink(0x3A1418))
        s.ellipse(120, inner - 9 * k, 15 * k + 2, 7 * k + 1, fill: Ink(0xE8667A))
    }

    /// Both grow from the upper jaw. The right one was broken long ago and capped in gold.
    private func tusks() {
        outlined("M74 142C72 176 76 208 92 232C102 206 106 176 106 146Z", tusk)
        s.shape("M99 150C99 176 96 202 92 224C100 204 103 176 103 148Z", fill: tuskDark)
        outlined("M134 146C135 164 138 178 142 190L166 186C170 170 170 158 168 142Z", tusk)
        s.shape("M160 148C161 164 160 176 158 188L164 187C167 172 167 160 165 146Z", fill: tuskDark)
        outlined("M142 188L166 184C166 196 160 208 153 214C148 208 143 198 142 188Z", Self.gold)
        s.line("M147 194C148 199 150 203 152 206", Self.goldLight, 3.4)
        s.line("M144 186L164 183", Self.goldDark, 3)
    }

    private func whiskers(left: Bool) {
        var lines = ["M50 134L26 126", "M46 148L20 150"]
        if left { lines.append("M56 162L34 176") }
        for d in lines {
            s.line(d, Self.outline, 10)
            s.line(d, stache, 4.5)
        }
    }

    private func lobe() {
        outlined("M120 104C102 94 60 98 44 130C36 150 52 170 82 170C100 170 114 162 120 148Z", stache)
        s.shape("M47 150C52 164 66 170 82 170C100 170 114 162 120 148C112 156 98 160 84 160C68 160 54 158 47 150Z", fill: stacheDark)
        for d in ["M72 126L60 140", "M88 130L80 148", "M104 130L100 150"] {
            s.line(d, stacheDark, 4.5)
        }
    }

    /// Two lobes that pivot at the nose. A positive smile hoists the ends, a negative one lets them droop.
    private func moustache(smile: CGFloat, lift: CGFloat) {
        s.group {
            s.translate(0, lift)
            s.rotate(smile * 14, around: 120, 118)
            whiskers(left: true)
            lobe()
        }
        s.group {
            s.translate(240, lift)
            s.scale(-1, 1)
            s.rotate(smile * 14, around: 120, 118)
            whiskers(left: false)
            lobe()
        }
    }

    private func nose(lift: CGFloat) {
        s.group {
            s.translate(0, lift)
            s.shape("M100 104C106 94 134 94 140 104C142 116 128 122 120 122C112 122 98 116 100 104Z", fill: Self.ink, stroke: Self.outline, width: 3)
            s.ellipse(112, 103, 7, 3.6, fill: Ink.white.opacity(0.7))
        }
    }

    private func eye(_ cx: CGFloat, _ cy: CGFloat, _ kind: Eye, look: CGPoint, big: Bool) {
        var r: CGFloat = big ? 19 : 16
        switch kind {
        case .closed:
            s.circle(cx, cy, r, fill: hideLight, stroke: Self.outline, width: 4.5)
            s.line("M\(cx - 11) \(cy - 1)C\(cx - 5) \(cy + 7) \(cx + 5) \(cy + 7) \(cx + 11) \(cy - 1)", Self.ink, 5.5)
        case .happy:
            s.circle(cx, cy, r, fill: hideLight, stroke: Self.outline, width: 4.5)
            s.line("M\(cx - 11) \(cy + 5)C\(cx - 5) \(cy - 8) \(cx + 5) \(cy - 8) \(cx + 11) \(cy + 5)", Self.ink, 5.5)
        case .dizzy:
            s.circle(cx, cy, r, fill: .white, stroke: Self.outline, width: 4.5)
            let spiral = CGMutablePath()
            for i in 0..<40 {
                let t = CGFloat(i) / 39 * 3.6 * .pi
                let radius = 1 + (r - 5) * CGFloat(i) / 39
                let point = CGPoint(x: cx + radius * cos(t), y: cy + radius * sin(t))
                if i == 0 { spiral.move(to: point) } else { spiral.addLine(to: point) }
            }
            s.paint(spiral, fill: nil, stroke: Self.ink, width: 3, cap: .round, join: .miter)
        case .heart:
            s.circle(cx, cy, r, fill: .white, stroke: Self.outline, width: 4.5)
            s.shape("M\(cx) \(cy + r * 0.66)C\(cx - r) \(cy) \(cx - r * 0.5) \(cy - r * 0.8) \(cx) \(cy - r * 0.2)C\(cx + r * 0.5) \(cy - r * 0.8) \(cx + r) \(cy) \(cx) \(cy + r * 0.66)Z", fill: Ink(0xE5383B))
        case .squint:
            s.circle(cx, cy, r, fill: hideLight, stroke: Self.outline, width: 4.5)
            s.line("M\(cx - 11) \(cy)H\(cx + 11)", Self.ink, 6)
        case .open, .lid, .tired, .wide, .small, .big:
            let pupil = kind == .wide ? r * 0.24 : kind == .lid ? r * 0.52 : r * 0.5
            if kind == .wide { r += 3 }
            s.circle(cx, cy, r, fill: .white, stroke: Self.outline, width: 4.5)
            s.clippedToCircle(cx, cy, r) {
                s.circle(cx + look.x, cy + look.y, pupil, fill: Self.ink)
                if kind != .wide {
                    s.circle(cx + look.x - pupil * 0.35, cy + look.y - pupil * 0.4, pupil * 0.28, fill: .white)
                }
                if kind == .lid {
                    // One slanted lid carries the whole attitude: it drops towards the nose.
                    let right = cx > 120
                    let inner: CGFloat = right ? 3 : -4
                    let outer: CGFloat = right ? -4 : 3
                    s.shape("M\(cx - 30) \(cy - 30)H\(cx + 30)V\(cy + outer)L\(cx - 30) \(cy + inner)Z", fill: hide)
                    s.plain("M\(cx - 30) \(cy + inner)L\(cx + 30) \(cy + outer)", Self.outline, 5)
                }
                if kind == .tired {
                    s.rect(cx - 30, cy - 30, 60, 30, fill: hide)
                    s.plain("M\(cx - 30) \(cy)H\(cx + 30)", Self.outline, 5)
                }
            }
        }
    }

    /// Bushy and pale, like the moustache.
    private func brow(_ cx: CGFloat, _ cy: CGFloat, side: CGFloat, _ brow: Brow) {
        s.group {
            s.translate(cx, cy - brow.lift)
            s.scale(-side, 1)
            s.rotate(brow.rotation)
            s.shape("M-24 4C-16 -9 10 -11 25 0C14 -1 -6 1 -18 11Z", fill: stache, stroke: Self.outline, width: 4.5)
        }
    }

    private func monocle(_ cx: CGFloat, _ cy: CGFloat, _ r: CGFloat) {
        s.circle(cx, cy, r, fill: Ink(0xCFEDF5, alpha: 0.06))
        s.clippedToCircle(cx, cy, r) {
            s.shape("M\(cx - r) \(cy - 2)L\(cx - 2) \(cy - r)H\(cx + 9)L\(cx - r) \(cy + 9)Z", fill: Ink.white.opacity(0.42))
        }
        s.circle(cx, cy, r, fill: nil, stroke: Self.outline, width: 11)
        s.circle(cx, cy, r, fill: nil, stroke: Self.gold, width: 6)
        s.line("M\(cx - r * 0.76) \(cy - r * 0.64)A\(r) \(r) 0 0 1 \(cx - r * 0.1) \(cy - r)", Self.goldLight, 3)
    }

    private func chain(_ x0: CGFloat, _ y0: CGFloat, _ x1: CGFloat, _ y1: CGFloat, sag: CGFloat) {
        let d = "M\(x0) \(y0)Q\((x0 + x1) / 2) \((y0 + y1) / 2 + sag) \(x1) \(y1)"
        s.line(d, Self.outline, 5.5)
        s.line(d, Self.gold, 2.6)
    }

    private func bowler(_ hat: Hat, flower: Bool = false) {
        s.group {
            s.translate(hat.x, hat.y)
            s.rotate(hat.tilt)
            outlined("M-62 -3C-34 15 34 15 62 -3C60 14 34 24 0 24C-34 24 -60 14 -62 -3Z", Self.hatInk)
            outlined("M-38 3C-44 -46 44 -46 38 3C14 13 -14 13 -38 3Z", Self.hatInk)
            s.shape("M-37 -10C-14 -1 14 -1 37 -10L38 3C14 13 -14 13 -38 3Z", fill: Self.band, stroke: Self.outline, width: 3.5)
            s.line("M-25 -13C-23 -21 -15 -26 -7 -27", Self.hatLight, 5)
            if flower {
                let pink = Ink(0xFF8FB8)
                let petals = stride(from: CGFloat(0), to: 360, by: 72).map { degrees -> CGPoint in
                    let a = (degrees - 90) * .pi / 180
                    return CGPoint(x: -24 + 8.5 * cos(a), y: -4 + 8.5 * sin(a))
                }
                for petal in petals { s.circle(petal.x, petal.y, 7, fill: pink, stroke: Self.outline, width: 3) }
                for petal in petals { s.circle(petal.x, petal.y, 5.6, fill: pink) }
                s.circle(-24, -4, 5, fill: Self.gold, stroke: Self.outline, width: 2.4)
            }
        }
    }

    /// Date hats replace the bowler. Same anchor, same outline.
    private func headwear(_ kind: Headwear, _ hat: Hat) {
        s.group {
            s.translate(hat.x, hat.y)
            s.rotate(hat.tilt)
            switch kind {
            case .santa:
                let cuff = Ink(0xFFF6EE)
                outlined("M-44 6C-38 -32 -6 -56 34 -46C54 -41 66 -24 72 -4C60 -18 50 -18 44 -8C42 -4 42 2 42 6Z", Ink(0xD23340))
                s.shape("M30 -41C46 -36 58 -24 64 -12C56 -16 48 -14 42 -8C38 -18 36 -30 30 -41Z", fill: Ink(0xA82230))
                outlined("M-52 2C-24 14 24 14 52 2C58 6 58 20 50 24C24 34 -24 34 -50 24C-58 20 -58 6 -52 2Z", cuff)
                s.circle(74, 4, 12, fill: cuff, stroke: Self.outline, width: Self.edge)
            case .witch:
                let cloth = Ink(0x3A2A5E)
                outlined("M-78 8C-40 -6 40 -6 78 8C40 26 -40 26 -78 8Z", cloth)
                outlined("M-30 8C-24 -20 -14 -52 8 -74C12 -66 8 -60 12 -56C18 -50 22 -46 26 -40C28 -24 30 -8 32 8C12 14 -12 14 -30 8Z", cloth)
                s.line("M-14 -8C-10 -26 -4 -42 4 -56", Ink(0x6A55A8), 5)
                s.shape("M-29 -2C-12 4 12 4 31 -2L32 8C12 14 -12 14 -30 8Z", fill: Ink(0xF05D23), stroke: Self.outline, width: 3.5)
                s.rect(-8, -3, 16, 13, corner: 2, fill: Self.gold, stroke: Self.outline, width: 3)
            case .party:
                let pink = Ink(0xF72585)
                outlined("M-32 8L0 -70L32 8C12 16 -12 16 -32 8Z", Ink(0x4CC9F0))
                s.shape("M-25 -9C-8 -3 8 -3 25 -9L19 -25C6 -20 -6 -20 -19 -25Z", fill: .white)
                s.shape("M-13 -40C-4 -37 4 -37 13 -40L8 -52C3 -50 -3 -50 -8 -52Z", fill: pink)
                s.circle(0, -74, 10, fill: pink, stroke: Self.outline, width: Self.edge)
            case .scholar:
                outlined("M-38 -2H38V14C20 24 -20 24 -38 14Z", Ink(0x23233A))
                outlined("M0 -30L82 -8L0 14L-82 -8Z", Self.hatInk)
                s.line("M-62 -9L-1 -25", Self.hatLight, 3.6)
                s.line("M0 -8L56 2V30", Self.outline, 8.5)
                s.line("M0 -8L56 2V30", Self.gold, 4)
                s.shape("M49 28H63L65 48H47Z", fill: Self.gold, stroke: Self.outline, width: 4.5)
                s.circle(0, -8, 5, fill: Self.gold, stroke: Self.outline, width: 3)
            case .nightcap:
                let light = Ink(0xE6E9F8)
                outlined("M-44 6C-42 -30 -10 -50 24 -42C56 -34 76 -2 80 36C68 26 58 16 46 6Z", Ink(0x6C7BC9))
                s.shape("M-16 -32C-16 -18 -16 -6 -14 8L4 10C2 -8 4 -24 6 -42C-4 -42 -10 -38 -16 -32Z", fill: light)
                s.shape("M28 -40C30 -24 30 -10 28 8L40 6C44 -6 44 -18 42 -32C38 -36 32 -38 28 -40Z", fill: light)
                outlined("M-50 2C-24 12 24 12 50 2C54 8 54 18 50 22C24 30 -24 30 -50 22C-54 18 -54 8 -50 2Z", light)
                s.circle(82, 42, 11, fill: light, stroke: Self.outline, width: Self.edge)
            case .flower:
                break
            }
        }
    }

    /// Worn instead of the monocle on Programmers' Day and after the Konami code.
    private func pixelGlasses() {
        s.shape("M34 76H204V86H190V98H182V106H138V98H130V88H112V98H104V106H62V98H52V86H34Z", fill: Ink(0x0E0D12), stroke: Self.outline, width: 4)
        for box in [(62, 16), (82, 8), (140, 14), (158, 8)] as [(CGFloat, CGFloat)] {
            s.rect(box.0, 82, box.1, 7, fill: .white)
        }
    }

    /// The reward for a hundred catches: bitten in the middle, held across the mouth.
    private func fish() {
        let dark = Ink(0x5E93B8)
        outlined("M36 168L4 142C12 158 12 180 4 196Z", dark)
        outlined("M112 150C126 128 158 130 176 148Z", dark)
        outlined("M30 168C60 140 180 136 228 164C236 170 234 178 226 182C180 200 60 198 30 168Z", Ink(0x7FB3D5))
        s.shape("M44 174C84 190 180 192 224 180C180 196 66 196 44 174Z", fill: Ink(0xD5E9F4))
        s.line("M190 148C182 160 182 176 190 188", Ink(0x4C7FA3), 4.5)
        for (x, y) in [(70, 160), (92, 156), (114, 154), (136, 154), (158, 156)] as [(CGFloat, CGFloat)] {
            s.line("M\(x) \(y)C\(x + 6) \(y + 5) \(x + 6) \(y + 11) \(x) \(y + 16)", dark, 3.2)
        }
        s.circle(208, 162, 9.5, fill: .white, stroke: Self.outline, width: 4)
        s.line("M204 158L212 166M212 158L204 166", Self.ink, 3)
    }

    private func cigar(_ x: CGFloat, _ y: CGFloat, _ rotation: CGFloat, lit: Bool, length: CGFloat = 108, thickness w: CGFloat = 17) {
        s.group {
            s.translate(x, y)
            s.rotate(rotation)
            s.rect(0, -w / 2, length + 12, w, corner: 4, fill: Ink(0x7A4A28), stroke: Self.outline, width: Self.edge)
            s.rect(2, -w / 2, length, w * 0.3, fill: Ink(0xA06A3C))
            s.rect(length * 0.68, -w / 2, 9, w, fill: Self.band)
            s.rect(length - 2, -w / 2, 7, w, fill: lit ? Ink(0xFF7A2A) : Ink(0x6E6A64))
            s.rect(length + 5, -w / 2, 7, w, corner: 2, fill: Ink(0xCFCBC4))
        }
    }

    /// Three flat puffs rising from the ember.
    private func puffs(_ x: CGFloat, _ y: CGFloat, phase: CGFloat) {
        for k in 0..<3 {
            let f = (phase + CGFloat(k) / 3).truncatingRemainder(dividingBy: 1)
            s.circle(x + sin(f * 6.3) * 7 + f * 8, y - f * 70, 3 + f * 9, fill: Ink(0xB4B1C2, alpha: (1 - f) * 0.95))
        }
    }

    private func effect(_ effect: Effect) {
        let red = Ink(0xE5383B)
        switch effect {
        case .bang(let x, let y):
            s.rect(x, y, 14, 36, corner: 7, fill: red, stroke: Self.outline, width: 5)
            s.circle(x + 7, y + 50, 8, fill: red, stroke: Self.outline, width: 5)
        case .zed(let x, let y, let size, let opacity):
            s.line("M\(x) \(y)h\(size)l\(-size) \(size)h\(size)", Ink(0x5C6BC9, alpha: opacity), size * 0.28)
        case .question(let x, let y):
            s.glyph("?", x: x, y: y, size: 56, fill: Ink(0x3F6FE0), stroke: Self.outline, width: 4)
        case .drop(let x, let y):
            s.shape("M\(x) \(y)C\(x - 8) \(y + 13) \(x - 8) \(y + 22) \(x) \(y + 22)C\(x + 8) \(y + 22) \(x + 8) \(y + 13) \(x) \(y)Z", fill: Ink(0x6FC3F0), stroke: Self.outline, width: 4)
        case .star(let x, let y, let radius):
            let star = CGMutablePath()
            for i in 0..<10 {
                let a = -CGFloat.pi / 2 + CGFloat(i) * .pi / 5
                let r = i % 2 == 0 ? radius : radius * 0.46
                let point = CGPoint(x: x + cos(a) * r, y: y + sin(a) * r)
                if i == 0 { star.move(to: point) } else { star.addLine(to: point) }
            }
            star.closeSubpath()
            s.paint(star, fill: Self.gold, stroke: Self.outline, width: 3.5)
        case .sound(let phase):
            for k in 0..<2 {
                let f = (phase * 2 + CGFloat(k) / 2).truncatingRemainder(dividingBy: 1)
                let r = (12 + f * 22).rounded()
                let x = (204 + r * 0.6).rounded()
                s.line("M\(x) \((190 - r).rounded())A\(r) \(r) 0 0 1 \(x) \((190 + r).rounded())", Ink(0x5C6BC9, alpha: 1 - f), 6)
            }
        }
    }
}
