import Foundation

/// Claude's replies split into what a reader sees: paragraphs, headings, list items and code.
public enum TextBlock: Sendable, Equatable {
    case paragraph(String)
    case heading(String)
    case bullet(String)
    case code(String)

    public static func parse(_ text: String) -> [TextBlock] {
        var blocks: [TextBlock] = []
        var paragraph: [String] = []
        var code: [String]?

        func flush() {
            if !paragraph.isEmpty {
                blocks.append(.paragraph(paragraph.joined(separator: " ")))
                paragraph = []
            }
        }

        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") {
                if let finished = code {
                    blocks.append(.code(finished.joined(separator: "\n")))
                    code = nil
                } else {
                    flush()
                    code = []
                }
                continue
            }
            if code != nil {
                code?.append(raw)
            } else if line.isEmpty {
                flush()
            } else if line.hasPrefix("#") {
                flush()
                blocks.append(.heading(String(line.drop { $0 == "#" }).trimmingCharacters(in: .whitespaces)))
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                flush()
                blocks.append(.bullet(String(line.dropFirst(2))))
            } else {
                paragraph.append(line)
            }
        }
        flush()
        // A fence left open by a text cut in the middle still shows as code.
        if let finished = code { blocks.append(.code(finished.joined(separator: "\n"))) }
        return blocks
    }
}
