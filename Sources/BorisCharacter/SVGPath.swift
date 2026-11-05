import CoreGraphics
import Foundation

/// Turns SVG path data into a `CGPath`, so the drawing stays the same data as in `design/tools/walrus/`.
enum SVGPath {
    static func path(_ d: String) -> CGPath {
        let path = CGMutablePath()
        var reader = Reader(d)
        var command: UInt8 = 0
        var current = CGPoint.zero
        var start = CGPoint.zero
        while let next = reader.command(after: command) {
            command = next
            let relative = command >= 97
            let origin = relative ? current : .zero
            switch command | 32 {
            case 109: // m
                current = reader.point(origin)
                start = current
                path.move(to: current)
                command = relative ? 108 : 76
            case 108: // l
                current = reader.point(origin)
                path.addLine(to: current)
            case 104: // h
                current.x = reader.number() + origin.x
                path.addLine(to: current)
            case 118: // v
                current.y = reader.number() + origin.y
                path.addLine(to: current)
            case 99: // c
                let c1 = reader.point(origin)
                let c2 = reader.point(origin)
                current = reader.point(origin)
                path.addCurve(to: current, control1: c1, control2: c2)
            case 113: // q
                let c = reader.point(origin)
                current = reader.point(origin)
                path.addQuadCurve(to: current, control: c)
            case 97: // a
                let rx = reader.number()
                _ = reader.number()
                _ = reader.number()
                let large = reader.number() != 0
                let sweep = reader.number() != 0
                let end = reader.point(origin)
                addArc(to: path, from: current, to: end, radius: rx, large: large, sweep: sweep)
                current = end
            case 122: // z
                path.closeSubpath()
                current = start
            default:
                return path
            }
        }
        return path
    }

    /// Circular arcs only, which is all the drawing uses.
    private static func addArc(to path: CGMutablePath, from a: CGPoint, to b: CGPoint, radius r: CGFloat, large: Bool, sweep: Bool) {
        let hx = (a.x - b.x) / 2
        let hy = (a.y - b.y) / 2
        let squared = hx * hx + hy * hy
        guard squared > 0 else { return }
        let k = (max(0, r * r - squared) / squared).squareRoot() * (large != sweep ? 1 : -1)
        let center = CGPoint(x: k * hy + (a.x + b.x) / 2, y: -k * hx + (a.y + b.y) / 2)
        path.addArc(center: center, radius: r, startAngle: atan2(a.y - center.y, a.x - center.x), endAngle: atan2(b.y - center.y, b.x - center.x), clockwise: !sweep)
    }

    private struct Reader {
        let bytes: [UInt8]
        var index = 0

        init(_ text: String) {
            bytes = Array(text.utf8)
        }

        mutating func skipSpace() {
            while index < bytes.count, bytes[index] == 32 || bytes[index] == 44 || bytes[index] == 10 { index += 1 }
        }

        /// The next command letter. Numbers without a letter repeat the last command.
        mutating func command(after last: UInt8) -> UInt8? {
            skipSpace()
            guard index < bytes.count else { return nil }
            let byte = bytes[index]
            let isLetter = (byte | 32) >= 97 && (byte | 32) <= 122 && byte != 101 && byte != 69
            if isLetter {
                index += 1
                return byte
            }
            return last == 0 || last | 32 == 122 ? nil : last
        }

        mutating func point(_ origin: CGPoint) -> CGPoint {
            let x = number()
            let y = number()
            return CGPoint(x: x + origin.x, y: y + origin.y)
        }

        mutating func number() -> CGFloat {
            skipSpace()
            let begin = index
            if index < bytes.count, bytes[index] == 45 || bytes[index] == 43 { index += 1 }
            while index < bytes.count {
                let byte = bytes[index]
                let isExponent = (byte == 101 || byte == 69) && index > begin
                let isExponentSign = (byte == 45 || byte == 43) && (bytes[index - 1] == 101 || bytes[index - 1] == 69)
                guard (byte >= 48 && byte <= 57) || byte == 46 || isExponent || isExponentSign else { break }
                index += 1
            }
            return CGFloat(Double(String(decoding: bytes[begin..<index], as: UTF8.self)) ?? 0)
        }
    }
}
