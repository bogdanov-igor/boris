import CoreGraphics
import CoreText
import Foundation
import ImageIO
import BorisCore
import BorisCharacter

// Control sheets for checking the drawing by eye: every state in every style, at real size on light and dark.
// Usage: boris-sheet <out.png> [--stills <folder>]
// With --stills it also writes each state the way `design/walrus/` has it, to compare pixel by pixel.

func write(_ image: CGImage?, to path: String) {
    guard let image, let target = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, "public.png" as CFString, 1, nil) else { return }
    CGImageDestinationAddImage(target, image, nil)
    CGImageDestinationFinalize(target)
}

func canvas(_ width: Int, _ height: Int) -> CGContext {
    CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
}

/// Fills an opaque-free icon with one colour, the way the system tints a template image.
func tinted(_ image: CGImage?, _ gray: CGFloat) -> CGImage? {
    guard let image else { return nil }
    let ctx = canvas(image.width, image.height)
    let box = CGRect(x: 0, y: 0, width: image.width, height: image.height)
    ctx.clip(to: box, mask: image)
    ctx.setFillColor(gray: gray, alpha: 1)
    ctx.fill(box)
    return ctx.makeImage()
}

func label(_ text: String, centeredIn cell: CGRect, on ctx: CGContext) {
    let attributes: [CFString: Any] = [kCTFontAttributeName: CTFontCreateWithName("Helvetica" as CFString, 20, nil), kCTForegroundColorAttributeName: CGColor(gray: 0.53, alpha: 1)]
    guard let string = CFAttributedStringCreate(nil, text as CFString, attributes as CFDictionary) else { return }
    let line = CTLineCreateWithAttributedString(string)
    let width = CTLineGetTypographicBounds(line, nil, nil, nil)
    ctx.textPosition = CGPoint(x: cell.midX - width / 2, y: cell.minY + 6)
    CTLineDraw(line, ctx)
}

let names: [PoseName: String] = [.watch: "Дежурит", .work: "Работает", .happy: "Радуется", .alarm: "Тревога", .sleep: "Спит", .wait: "Ждёт", .limit: "Устал", .broken: "Сломалось", .alert: "Настороже", .stopped: "Хм?"]
let order = PoseName.allCases
let cell = 170
let time: CGFloat = 6 / CGFloat(Timeline.framesPerLoop)

guard CommandLine.arguments.count > 1 else {
    print("usage: boris-sheet <out.png> [--stills <folder>]")
    exit(2)
}
let out = CommandLine.arguments[1]

// The same layout as design/walrus/preview.png.
let height = 30 + cell * 2 + 54
let sheet = canvas(cell * order.count, height)
for (index, name) in order.enumerated() {
    let x = index * cell
    label(names[name] ?? "", centeredIn: CGRect(x: x, y: height - 30, width: cell, height: 30), on: sheet)
    let full = Renderer.image(Timeline.full(name, t: time), pixels: cell)
    let simple = Renderer.image(Timeline.simple(name, t: time, mono: false), pixels: cell)
    if let full { sheet.draw(full, in: CGRect(x: x, y: height - 30 - cell, width: cell, height: cell)) }
    if let simple { sheet.draw(simple, in: CGRect(x: x, y: height - 30 - 2 * cell, width: cell, height: cell)) }
    let mono = Timeline.simple(name, t: time, mono: true)
    if let black = Renderer.template(mono, scale: 2) { sheet.draw(black, in: CGRect(x: x + 36, y: 8, width: 42, height: 36)) }
    if let white = tinted(Renderer.template(mono, scale: 2), 1) { sheet.draw(white, in: CGRect(x: x + 92, y: 8, width: 42, height: 36)) }
}
write(sheet.makeImage(), to: out)

// Real menu bar sizes on light and dark, then the same pixels enlarged: 2x, 1x, and 1x as a person with a plain display sees it.
let rowHeight = 48
let check = canvas(90 * order.count, rowHeight * 4)
for (band, dark) in [false, true].enumerated() {
    let background: CGFloat = dark ? 0.16 : 0.93
    let ink: CGFloat = dark ? 1 : 0
    let top = rowHeight * 4 - rowHeight * (band * 2 + 1)
    check.setFillColor(gray: background, alpha: 1)
    check.fill(CGRect(x: 0, y: top - rowHeight, width: 90 * order.count, height: rowHeight * 2))
    for (index, name) in order.enumerated() {
        let pose = Timeline.simple(name, t: name.keyTime, mono: true)
        let x = index * 90
        check.interpolationQuality = .none
        if let high = tinted(Renderer.template(pose, scale: 2), ink) {
            check.draw(high, in: CGRect(x: x + 4, y: top + 6, width: 42, height: 36))
        }
        if let low = tinted(Renderer.template(pose, scale: 1), ink) {
            check.draw(low, in: CGRect(x: x + 56, y: top + 15, width: 21, height: 18))
            check.draw(low, in: CGRect(x: x + 4, y: top - rowHeight + 3, width: 21 * 2, height: 18 * 2))
        }
        if let high = tinted(Renderer.template(pose, scale: 2), ink) {
            check.draw(high, in: CGRect(x: x + 48, y: top - rowHeight + 3, width: 42, height: 36))
        }
    }
}
write(check.makeImage(), to: out.replacingOccurrences(of: ".png", with: "-check.png"))

// Every outfit from the front, half turned and from behind: what he wears must stay on.
let outfits = Outfit.allCases
let sides: [Pose] = [Pose(), Timeline.act(.spin, t: 0.2), Timeline.act(.back, t: 0)]
let wardrobe = canvas(cell * outfits.count, 30 + cell * sides.count)
wardrobe.setFillColor(gray: 0.93, alpha: 1)
wardrobe.fill(CGRect(x: 0, y: 0, width: cell * outfits.count, height: 30 + cell * sides.count))
for (column, outfit) in outfits.enumerated() {
    label(outfit.rawValue, centeredIn: CGRect(x: column * cell, y: cell * sides.count, width: cell, height: 30), on: wardrobe)
    for (row, pose) in sides.enumerated() {
        if let image = Renderer.image(Dress.apply(outfit, to: pose), pixels: cell, roomy: true) {
            wardrobe.draw(image, in: CGRect(x: column * cell, y: cell * (sides.count - 1 - row), width: cell, height: cell))
        }
    }
}
write(wardrobe.makeImage(), to: out.replacingOccurrences(of: ".png", with: "-outfits.png"))

if let at = CommandLine.arguments.firstIndex(of: "--stills"), CommandLine.arguments.count > at + 1 {
    let folder = CommandLine.arguments[at + 1]
    for name in order {
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let t = name.keyTime
        write(Renderer.image(Timeline.full(name, t: t), pixels: 1024), to: "\(folder)/full-\(name.rawValue).png")
        write(Renderer.image(Timeline.simple(name, t: t, mono: false), pixels: 1024), to: "\(folder)/simple-\(name.rawValue).png")
        let mono = Timeline.simple(name, t: t, mono: true)
        write(Renderer.template(mono, scale: 2), to: "\(folder)/tray2-\(name.rawValue).png")
        write(Renderer.template(mono, scale: 1), to: "\(folder)/tray1-\(name.rawValue).png")
    }
    for outfit in Outfit.allCases where outfit != .none {
        write(Renderer.image(Dress.shelf(outfit), pixels: 1024, roomy: true), to: "\(folder)/outfit-full-\(outfit.rawValue).png")
        write(Renderer.image(Dress.shelfSimple(outfit, mono: false), pixels: 1024, roomy: true), to: "\(folder)/outfit-simple-\(outfit.rawValue).png")
        guard outfit != .fish else { continue }
        let mono = Dress.shelfSimple(outfit, mono: true)
        write(Renderer.template(mono, scale: 2), to: "\(folder)/outfit-tray2-\(outfit.rawValue).png")
        write(Renderer.template(mono, scale: 1), to: "\(folder)/outfit-tray1-\(outfit.rawValue).png")
    }
    for act in Act.allCases {
        write(Renderer.image(Timeline.act(act, t: act.stillTime), pixels: 1024, roomy: true), to: "\(folder)/act-\(act.rawValue).png")
    }
}
