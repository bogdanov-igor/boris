import Foundation
import ImageIO

/// The states a pack can draw, by the names of their folders. What a pack leaves out shows its base pose.
public enum WalrusPose: String, CaseIterable, Sendable, Hashable {
    case working, waiting, happy, hmm, alert, tired, alarm, broken, sleeping

    public init(mood: Mood) {
        switch mood {
        case .working: self = .working
        case .waiting: self = .waiting
        case .happy: self = .happy
        case .hmm: self = .hmm
        case .alert: self = .alert
        case .tired: self = .tired
        case .alarm: self = .alarm
        case .broken: self = .broken
        case .sleeping: self = .sleeping
        }
    }
}

/// A walrus made of files. The format is in `docs/pack-format.md`. There is no code in a pack, only pictures and text.
public struct WalrusPack: Sendable, Equatable, Identifiable {
    /// The name of its folder on the shelf.
    public var id: String
    public var folder: URL
    public var name: String
    public var author: String?
    public var baseLanguage: String
    public var framesPerSecond: Double
    public var baseFrames: [URL]
    public var poses: [WalrusPose: [URL]]
    public var baseIcon: URL
    public var icons: [WalrusPose: URL]
    public var lines: [String: [WalrusCue: [String]]]
    public var sounds: [URL]

    /// `nil` is the base pose, shown in the wardrobe and in About.
    public func frames(for pose: WalrusPose?) -> [URL] {
        pose.flatMap { poses[$0] } ?? baseFrames
    }

    public func icon(for pose: WalrusPose?) -> URL {
        pose.flatMap { icons[$0] } ?? baseIcon
    }

    /// In the interface language if the pack has it, otherwise in its base language. A project name can only go where the author left room for it.
    public func lines(for cue: WalrusCue, project: String?, language: String) -> [String] {
        let book = lines[language]?[cue].flatMap { $0.isEmpty ? nil : $0 } ?? lines[baseLanguage]?[cue] ?? []
        let named = book.filter { $0.contains(Self.projectMark) }
        guard let project else { return book.filter { !$0.contains(Self.projectMark) } }
        // A failure should say where it happened, whenever the pack can.
        let chosen = cue == .failure && !named.isEmpty ? named : book
        return chosen.map { $0.replacingOccurrences(of: Self.projectMark, with: project) }
    }

    public static let projectMark = "{project}"
}

/// What is wrong with a pack. Paths are relative to the pack, so the list can be shown and copied.
public enum WalrusPackProblem: Sendable, Equatable, Hashable {
    case noManifest
    case badManifest
    case noName
    case noBaseLanguage
    case noBasePose
    case noTrayIcon
    case noLines(language: String)
    case badLines(language: String)
    case noLinesForCue(WalrusCue)
    /// Every line of this cue names a project, and some events have none.
    case noPlainLine(WalrusCue)
    case lineTooLong(WalrusCue)
    case badImage(String)
    case tooLarge(String)
    case tooManyFrames(String)
    case link(String)
    case cannotCopy
}

public struct WalrusPackRejection: Error, Sendable, Equatable {
    public var name: String
    public var problems: [WalrusPackProblem]

    public init(name: String, problems: [WalrusPackProblem]) {
        self.name = name
        self.problems = problems
    }
}

public enum WalrusPackReader {
    public static let maxFileBytes = 8 << 20
    public static let maxPackBytes = 256 << 20
    public static let maxSide = 2048
    public static let maxFrames = 240
    public static let maxLineLength = 240
    private static let textBytes = 1 << 20
    private static let soundTypes: Set<String> = ["aiff", "aif", "wav", "m4a", "mp3", "caf"]

    /// Finds the problems instead of stopping at the first one, so the person can fix them all at once.
    /// - Parameter inspectImages: looks inside every picture. A pack on the shelf was inspected when it came in.
    public static func read(_ folder: URL, inspectImages: Bool = true) -> Result<WalrusPack, WalrusPackRejection> {
        var problems: [WalrusPackProblem] = []
        var fallbackName = folder.lastPathComponent
        var bytes = 0

        func report(_ problem: WalrusPackProblem) {
            if !problems.contains(problem) { problems.append(problem) }
        }

        func entries(_ relative: String) -> [URL] {
            // No step on the way may lead out of the pack.
            var url = folder
            for part in relative.split(separator: "/").map(String.init) {
                url = url.appendingPathComponent(part, isDirectory: true)
                guard !isLink(url) else {
                    report(.link(String(url.path.dropFirst(folder.path.count + 1))))
                    return []
                }
            }
            let names = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
            // Built from the folder that was given, so the path inside the pack can always be found again.
            return names.filter { !$0.hasPrefix(".") }.map { url.appendingPathComponent($0) }
        }

        func pictures(_ relative: String) -> [URL] {
            let found = entries(relative)
                .filter { $0.pathExtension.lowercased() == "png" }
                .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            if found.count > maxFrames {
                problems.append(.tooManyFrames(relative))
                return []
            }
            return found.filter { checkImage($0, "\(relative)/\($0.lastPathComponent)") }
        }

        func checkImage(_ url: URL, _ relative: String) -> Bool {
            guard !isLink(url) else {
                problems.append(.link(relative))
                return false
            }
            let size = fileSize(url)
            bytes += size
            guard size <= maxFileBytes else {
                problems.append(.tooLarge(relative))
                return false
            }
            guard inspectImages else { return true }
            guard let shape = imageShape(url) else {
                problems.append(.badImage(relative))
                return false
            }
            guard shape.width <= maxSide, shape.height <= maxSide else {
                problems.append(.tooLarge(relative))
                return false
            }
            return true
        }

        var manifest: Manifest?
        let manifestURL = folder.appendingPathComponent("pack.json")
        if isLink(manifestURL) {
            problems.append(.link("pack.json"))
        } else if !FileManager.default.fileExists(atPath: manifestURL.path) {
            problems.append(.noManifest)
        } else if let data = text(manifestURL), let decoded = try? JSONDecoder().decode(Manifest.self, from: data) {
            manifest = decoded
            if let name = decoded.cleanName { fallbackName = name } else { problems.append(.noName) }
            if decoded.baseLanguage == nil { problems.append(.noBaseLanguage) }
        } else {
            problems.append(.badManifest)
        }

        let baseFrames = pictures("poses/base")
        if baseFrames.isEmpty, !problems.contains(where: { if case .tooManyFrames("poses/base") = $0 { return true } else { return false } }) { problems.append(.noBasePose) }
        var poses: [WalrusPose: [URL]] = [:]
        for pose in WalrusPose.allCases {
            let frames = pictures("poses/\(pose.rawValue)")
            if !frames.isEmpty { poses[pose] = frames }
        }

        let iconFiles = entries("icon")
        func icon(_ name: String) -> URL? {
            guard let url = iconFiles.first(where: { $0.lastPathComponent == "\(name).png" }), checkImage(url, "icon/\(name).png") else { return nil }
            return url
        }
        let baseIcon = icon("base")
        if baseIcon == nil, !iconFiles.contains(where: { $0.lastPathComponent == "base.png" }) { problems.append(.noTrayIcon) }
        var icons: [WalrusPose: URL] = [:]
        for pose in WalrusPose.allCases {
            if let url = icon(pose.rawValue) { icons[pose] = url }
        }

        var lines: [String: [WalrusCue: [String]]] = [:]
        for file in entries("lines") where file.pathExtension == "json" {
            let language = file.deletingPathExtension().lastPathComponent
            guard !isLink(file) else {
                problems.append(.link("lines/\(file.lastPathComponent)"))
                continue
            }
            guard let data = text(file), let decoded = try? JSONDecoder().decode([String: [String]].self, from: data) else {
                problems.append(.badLines(language: language))
                continue
            }
            var book: [WalrusCue: [String]] = [:]
            for cue in WalrusCue.allCases {
                let cleaned = (decoded[cue.rawValue] ?? []).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
                if cleaned.contains(where: { $0.count > maxLineLength }), !problems.contains(.lineTooLong(cue)) { problems.append(.lineTooLong(cue)) }
                if !cleaned.isEmpty { book[cue] = cleaned }
            }
            lines[language] = book
        }
        if let base = manifest?.baseLanguage {
            if let book = lines[base] {
                for cue in WalrusCue.allCases {
                    guard let found = book[cue] else {
                        problems.append(.noLinesForCue(cue))
                        continue
                    }
                    if found.allSatisfy({ $0.contains(WalrusPack.projectMark) }) { problems.append(.noPlainLine(cue)) }
                }
            } else if !problems.contains(.badLines(language: base)) {
                problems.append(.noLines(language: base))
            }
        }

        var sounds: [URL] = []
        for file in entries("sounds") where soundTypes.contains(file.pathExtension.lowercased()) {
            let relative = "sounds/\(file.lastPathComponent)"
            if isLink(file) {
                problems.append(.link(relative))
            } else if (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) != true {
                continue
            } else if fileSize(file) > maxFileBytes {
                problems.append(.tooLarge(relative))
            } else {
                bytes += fileSize(file)
                sounds.append(file)
            }
        }
        if bytes > maxPackBytes { problems.append(.tooLarge(folder.lastPathComponent)) }

        guard problems.isEmpty, let manifest, let name = manifest.cleanName, let base = manifest.baseLanguage, let baseIcon else {
            return .failure(WalrusPackRejection(name: fallbackName, problems: problems))
        }
        return .success(WalrusPack(
            id: folder.lastPathComponent,
            folder: folder,
            name: name,
            author: manifest.author,
            baseLanguage: base,
            framesPerSecond: min(max(manifest.framesPerSecond ?? 8, 1), 24),
            baseFrames: baseFrames,
            poses: poses,
            baseIcon: baseIcon,
            icons: icons,
            lines: lines,
            sounds: sounds
        ))
    }

    private struct Manifest: Decodable {
        var name: String?
        var author: String?
        var baseLanguage: String?
        var framesPerSecond: Double?

        var cleanName: String? {
            let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return trimmed.isEmpty ? nil : String(trimmed.prefix(80))
        }
    }

    private static func isLink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
    }

    private static func fileSize(_ url: URL) -> Int {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    }

    private static func text(_ url: URL) -> Data? {
        guard fileSize(url) <= textBytes else { return nil }
        return try? Data(contentsOf: url)
    }

    /// Actually decodes the picture, so a broken file is found now and not on screen.
    private static func imageShape(_ url: URL) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetType(source) as String? == "public.png",
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0
        else { return nil }
        let options = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 32] as CFDictionary
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options) == nil ? nil : (width, height)
    }
}

/// The folder where imported packs live. Only the files the format names are copied in, so whatever else was in the folder stays behind.
public struct WalrusPackShelf: Sendable {
    public let folder: URL

    public init(folder: URL) {
        self.folder = folder
    }

    public func list() -> [WalrusPack] {
        let folders = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
        return folders.compactMap { try? WalrusPackReader.read($0, inspectImages: false).get() }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// `nil` when the pack is gone or spoiled: the built-in walrus takes over.
    public func pack(id: String?) -> WalrusPack? {
        guard let id, !id.isEmpty, id == URL(fileURLWithPath: id).lastPathComponent else { return nil }
        return try? WalrusPackReader.read(folder.appendingPathComponent(id, isDirectory: true), inspectImages: false).get()
    }

    /// A pack with the same name is replaced: that is how a new version of it comes in.
    public func add(from source: URL) -> Result<WalrusPack, WalrusPackRejection> {
        let pack: WalrusPack
        switch WalrusPackReader.read(source) {
        case .failure(let rejection): return .failure(rejection)
        case .success(let read): pack = read
        }
        let manager = FileManager.default
        let id = UUID().uuidString
        let temporary = folder.appendingPathComponent(".\(id)", isDirectory: true)
        let target = folder.appendingPathComponent(id, isDirectory: true)
        let rejected = WalrusPackRejection(name: pack.name, problems: [.cannotCopy])
        do {
            try manager.createDirectory(at: temporary, withIntermediateDirectories: true)
            for file in Self.files(of: pack) {
                let relative = String(file.path.dropFirst(pack.folder.path.count + 1))
                let destination = temporary.appendingPathComponent(relative)
                try manager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try manager.copyItem(at: file, to: destination)
            }
            let older = list().filter { $0.name == pack.name }
            try manager.moveItem(at: temporary, to: target)
            for old in older { try? manager.removeItem(at: old.folder) }
        } catch {
            try? manager.removeItem(at: temporary)
            return .failure(rejected)
        }
        guard let placed = try? WalrusPackReader.read(target, inspectImages: false).get() else {
            try? manager.removeItem(at: target)
            return .failure(rejected)
        }
        return .success(placed)
    }

    public func remove(id: String) {
        guard id == URL(fileURLWithPath: id).lastPathComponent else { return }
        try? FileManager.default.removeItem(at: folder.appendingPathComponent(id, isDirectory: true))
    }

    private static func files(of pack: WalrusPack) -> [URL] {
        var files = [pack.folder.appendingPathComponent("pack.json"), pack.baseIcon] + pack.baseFrames + pack.poses.values.flatMap { $0 } + Array(pack.icons.values) + pack.sounds
        files += pack.lines.keys.map { pack.folder.appendingPathComponent("lines/\($0).json") }
        return files
    }
}
