import Foundation
@testable import BorisData

/// A throwaway folder removed when the value goes away.
final class TempFolder: @unchecked Sendable {
    let url: URL

    init() {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("boris-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: url) }

    @discardableResult
    func write(_ name: String, _ text: String) -> URL {
        let file = url.appendingPathComponent(name)
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? text.write(to: file, atomically: false, encoding: .utf8)
        return file
    }

    func append(_ name: String, _ text: String) {
        let file = url.appendingPathComponent(name)
        guard let handle = try? FileHandle(forWritingTo: file) else { return }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data(text.utf8))
        try? handle.close()
    }
}

enum Fixtures {
    static var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures")
    }

    struct Expected: Decodable {
        let status: [String: Int]
        let failureClass: [String: Int]
        let runs: Int
    }

    struct Manifest: Decodable {
        struct Run: Decodable {
            let project: String
            let session: String
            let journalModified: Double
            let finalModified: Double?
        }

        let takenAt: Double
        let runs: [String: Run]
    }

    static func expected() throws -> Expected {
        try JSONDecoder().decode(Expected.self, from: Data(contentsOf: root.appendingPathComponent("expected.json")))
    }

    static func manifest() throws -> Manifest {
        try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: root.appendingPathComponent("manifest.json")))
    }

    /// Copies the fixture world and restores file times, which git does not keep.
    static func world(into folder: TempFolder) throws -> ClaudePaths {
        let destination = folder.url.appendingPathComponent("world")
        try FileManager.default.copyItem(at: root.appendingPathComponent("world"), to: destination)
        let manifest = try manifest()
        for (run, info) in manifest.runs {
            let session = destination.appendingPathComponent("projects/\(info.project)/\(info.session)")
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSince1970: info.journalModified)],
                ofItemAtPath: session.appendingPathComponent("subagents/workflows/\(run)/journal.jsonl").path
            )
            if let final = info.finalModified {
                try FileManager.default.setAttributes(
                    [.modificationDate: Date(timeIntervalSince1970: final)],
                    ofItemAtPath: session.appendingPathComponent("workflows/\(run).json").path
                )
            }
        }
        return ClaudePaths(root: destination)
    }
}
