import Foundation

/// One of the person's own secret words. Typed in the main window, it shows their picture in his place,
/// says their lines one after another and plays their sound. The format is in `docs/secret-words.md`.
public struct SecretWord: Sendable, Equatable {
    /// In lower case, as it is typed.
    public var word: String
    public var lines: [String]
    public var picture: URL?
    public var sound: URL?
    /// How long the picture stays.
    public var seconds: TimeInterval

    public init(word: String, lines: [String], picture: URL? = nil, sound: URL? = nil, seconds: TimeInterval = SecretWordsReader.standardSeconds) {
        self.word = word
        self.lines = lines
        self.picture = picture
        self.sound = sound
        self.seconds = seconds
    }
}

/// Reads the folder of secret words. It lives on the person's Mac only: nothing of it is in the app or the repository.
/// What cannot be used is skipped quietly: these are jokes, not settings.
public enum SecretWordsReader {
    public static let fileName = "words.json"
    public static let shortestWord = 2
    public static let longestWord = 24
    public static let maxWords = 50
    public static let maxLines = 6
    public static let maxLineLength = 240
    public static let maxFileBytes = 8 << 20
    public static let standardSeconds: TimeInterval = 6
    static let seconds: ClosedRange<TimeInterval> = 2...30
    static let pictureTypes: Set<String> = ["png", "jpg", "jpeg", "heic", "gif", "webp", "tiff"]
    static let soundTypes: Set<String> = ["aiff", "aif", "wav", "m4a", "mp3", "caf"]

    public static func read(_ folder: URL) -> [SecretWord] {
        let file = folder.appendingPathComponent(fileName)
        guard let size = fileSize(file), size <= 1 << 20, let data = try? Data(contentsOf: file),
              let list = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return [] }
        let root = folder.resolvingSymlinksInPath().standardizedFileURL.path + "/"

        // Only a file inside the folder, of a known kind and a sane size. A link out of the folder is not followed.
        func inside(_ name: Any?, _ types: Set<String>) -> URL? {
            guard let name = name as? String, !name.isEmpty else { return nil }
            let url = folder.appendingPathComponent(name).resolvingSymlinksInPath().standardizedFileURL
            guard url.path.hasPrefix(root), types.contains(url.pathExtension.lowercased()),
                  let size = fileSize(url), size <= maxFileBytes else { return nil }
            return url
        }

        var seen = Set<String>()
        return list.prefix(maxWords).compactMap { entry in
            guard let raw = entry["word"] as? String else { return nil }
            let word = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard (shortestWord...longestWord).contains(word.count), !word.contains(where: \.isWhitespace), seen.insert(word).inserted else { return nil }
            let lines = ((entry["lines"] as? [Any]) ?? [])
                .compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .prefix(maxLines)
                .map { String($0.prefix(maxLineLength)) }
            let picture = inside(entry["picture"], pictureTypes)
            let sound = inside(entry["sound"], soundTypes)
            guard !lines.isEmpty || picture != nil || sound != nil else { return nil }
            let asked = (entry["seconds"] as? NSNumber)?.doubleValue ?? standardSeconds
            return SecretWord(word: word, lines: lines, picture: picture, sound: sound, seconds: min(max(asked, seconds.lowerBound), seconds.upperBound))
        }
    }

    /// What goes into a new folder, so the person can see the shape and change it.
    public static let example = """
    [
      {
        "word": "пример",
        "picture": "пример.png",
        "lines": ["Первая реплика.", "Вторая.", "Третья, самая смешная."],
        "sound": "пример.m4a",
        "seconds": 6
      }
    ]

    """

    private static func fileSize(_ url: URL) -> Int? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path), attributes[.type] as? FileAttributeType == .typeRegular else { return nil }
        return (attributes[.size] as? NSNumber)?.intValue
    }
}
