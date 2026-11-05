import Foundation

/// Reads a run's name and phase plan from `workflows/scripts/<name>-<runId>.js`.
public enum ScriptReader {
    public struct Info: Sendable, Equatable {
        public var name: String?
        public var phases: [String]
        public var description: String?
    }

    public static func read(scripts: URL, runId: String) -> Info? {
        let suffix = "-\(runId).js"
        guard let file = FileInfo.names(in: scripts).first(where: { $0.hasSuffix(suffix) }) else { return nil }
        let name = String(file.dropLast(suffix.count))
        guard let handle = try? FileHandle(forReadingFrom: scripts.appendingPathComponent(file)) else {
            return Info(name: name, phases: [], description: nil)
        }
        defer { try? handle.close() }
        // `meta` must come first in a workflow script, so the head of the file is enough.
        let head = (try? handle.read(upToCount: 64 * 1024)).flatMap { String(decoding: $0, as: UTF8.self) } ?? ""
        return Info(name: name.isEmpty ? nil : name, phases: phaseTitles(in: head), description: description(in: head))
    }

    /// Phases of a script at any path, used for runs started from a file.
    static func phases(at url: URL) -> [String] {
        phaseTitles(in: head(of: url))
    }

    static func description(at url: URL) -> String? {
        description(in: head(of: url))
    }

    private static func head(of url: URL) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        return (try? handle.read(upToCount: 64 * 1024)).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }

    /// The one-line summary from `meta`. Phases have their own text further on, so the search stops there.
    static func description(in script: String) -> String? {
        guard let start = script.range(of: "export const meta")?.upperBound else { return nil }
        let end = script.range(of: "phases", range: start..<script.endIndex)?.lowerBound ?? script.endIndex
        let block = String(script[start..<end])
        guard let regex = try? NSRegularExpression(pattern: "description\\s*:\\s*(?:'((?:[^'\\\\]|\\\\.)*)'|\"((?:[^\"\\\\]|\\\\.)*)\"|`([^`]*)`)") else { return nil }
        let ns = block as NSString
        guard let match = regex.firstMatch(in: block, range: NSRange(location: 0, length: ns.length)) else { return nil }
        for group in 1...3 where match.range(at: group).location != NSNotFound {
            let text = ns.substring(with: match.range(at: group)).replacingOccurrences(of: "\\'", with: "'").replacingOccurrences(of: "\\\"", with: "\"")
            return text.isEmpty ? nil : text
        }
        return nil
    }

    static func phaseTitles(in script: String) -> [String] {
        let start = script.range(of: "export const meta")?.upperBound ?? script.startIndex
        guard let keyword = script.range(of: "phases", range: start..<script.endIndex),
              let open = script.range(of: "[", range: keyword.upperBound..<script.endIndex)
        else { return [] }

        var depth = 0
        var end: String.Index?
        var quote: Character?
        var index = open.lowerBound
        while index < script.endIndex {
            let c = script[index]
            if let q = quote {
                if c == "\\" {
                    index = script.index(after: index)
                    if index == script.endIndex { break }
                } else if c == q {
                    quote = nil
                }
            } else if c == "'" || c == "\"" || c == "`" {
                quote = c
            } else if c == "[" {
                depth += 1
            } else if c == "]" {
                depth -= 1
                if depth == 0 {
                    end = index
                    break
                }
            }
            index = script.index(after: index)
        }
        guard let end else { return [] }
        let literal = String(script[open.lowerBound...end])
        guard let regex = try? NSRegularExpression(pattern: "title\\s*:\\s*(?:'([^']*)'|\"([^\"]*)\"|`([^`]*)`)") else { return [] }
        let ns = literal as NSString
        return regex.matches(in: literal, range: NSRange(location: 0, length: ns.length)).compactMap { match in
            for group in 1...3 where match.range(at: group).location != NSNotFound {
                return ns.substring(with: match.range(at: group))
            }
            return nil
        }
    }
}
