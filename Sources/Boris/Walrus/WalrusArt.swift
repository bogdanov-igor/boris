import AppKit
import BorisCharacter
import BorisCore
import ImageIO
import Observation

/// The one way to get a picture of the walrus, whoever drew him. Screens and the menu bar never ask which it is.
@MainActor
@Observable
final class WalrusArt {
    static let shared = WalrusArt()

    enum Source: Hashable {
        case drawn(WalrusFrame)
        /// An outfit on the wardrobe shelf, in the pose it looks best in.
        case shelf(Outfit)
        case file(URL)
    }

    private struct Key: Hashable {
        let source: Source
        let pixels: Int
        let simple: Bool
    }

    /// The pack in use. `nil` is the walrus drawn in code.
    var pack: WalrusPack? {
        didSet { if pack != oldValue { files = [:] } }
    }

    @ObservationIgnored private var stills: [Key: CGImage] = [:]
    @ObservationIgnored private var files: [Key: CGImage] = [:]

    func picture(_ source: Source, pixels: Int, simple: Bool) -> CGImage? {
        switch source {
        case .drawn(let frame):
            return simple ? Renderer.image(frame.simplePose(), pixels: pixels, roomy: true) : Renderer.image(frame.fullPose(), pixels: pixels, roomy: true)
        case .shelf(let outfit):
            return Renderer.image(Dress.shelfSimple(outfit, mono: false), pixels: pixels, roomy: true)
        case .file(let url):
            return Self.thumbnail(url, pixels: pixels)
        }
    }

    /// A picture that is drawn once and kept.
    func still(_ source: Source, pixels: Int, simple: Bool) -> CGImage? {
        let key = Key(source: source, pixels: pixels, simple: simple)
        if case .file = source {
            if let known = files[key] { return known }
            let made = picture(source, pixels: pixels, simple: simple)
            files[key] = made
            return made
        }
        if let known = stills[key] { return known }
        let made = picture(source, pixels: pixels, simple: simple)
        stills[key] = made
        return made
    }

    /// The menu bar icon of a pack. It is a template, painted by the system like the built-in one.
    func trayIcon(_ pack: WalrusPack, pose: PoseName) -> NSImage? {
        guard let image = NSImage(contentsOf: pack.icon(for: pose.packPose)) else { return nil }
        image.size = Renderer.iconPoints
        image.isTemplate = true
        return image
    }

    /// Reads a picture no larger than needed, so a big pack stays small in memory.
    static func thumbnail(_ url: URL, pixels: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: pixels,
        ] as CFDictionary
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options)
    }
}
