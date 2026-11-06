import BorisCore
import BorisData
import Foundation
import Testing

/// Boris talks to the network in two places: Telegram, if the person set it up, and the appcast in a released copy.
/// Anything new that can reach out has to come through here first, and say why.
@Suite("Исходящие соединения")
struct OutgoingConnectionsTests {
    private static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// What can open a connection, or carry an address.
    private static let means = [
        "URLSession", "URLRequest", "NSURLConnection", "URLConnection", "NWConnection", "NWListener", "NWBrowser", "NWEndpoint", "WKWebView",
        "CFStream", "CFSocket", "CFNetwork", "AF_INET", "getaddrinfo(", "gethostbyname(", "\"curl\"", "/curl", "\"wget\"", "/wget", "http://", "https://", "ws://", "wss://", "ftp://",
    ]

    /// Who may use what, and why. A monitor only asks the system about the connection, and reaches nothing.
    private static let allowed: [String: Set<String>] = [
        "Sources/BorisData/TelegramChannel.swift": ["URLSession", "URLRequest", "https://"],
        "Sources/Boris/Channels/NotificationHub.swift": ["URLSession"],
        // A link the person presses, which opens in their browser.
        "Sources/Boris/Usage/SpendCards.swift": ["https://"],
        // An invented address on a snapshot.
        "Sources/Boris/System/Updates.swift": ["https://"],
    ]

    private static func sources() -> [URL] {
        guard let walk = FileManager.default.enumerator(at: root.appendingPathComponent("Sources"), includingPropertiesForKeys: nil) else { return [] }
        return walk.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
    }

    @Test("Сеть трогают только Telegram и обновления")
    func onlyKnownPlaces() throws {
        let files = Self.sources()
        // A wrong folder would pass with nothing to look at.
        #expect(files.count > 50)
        var found: [String] = []
        for file in files {
            let path = String(file.path.dropFirst(Self.root.path.count + 1))
            let text = try String(contentsOf: file, encoding: .utf8)
            for means in Self.means where text.contains(means) && !(Self.allowed[path]?.contains(means) ?? false) {
                found.append("\(path): \(means)")
            }
        }
        #expect(found.isEmpty, "new ways out: \(found)")
    }

    @Test("В Sparkle идёт только адрес ленты, и только из Updates.swift")
    func sparkleStaysInOneFile() throws {
        for file in Self.sources() where !["Updates.swift", "DevUpdateCheck.swift"].contains(file.lastPathComponent) {
            let text = try String(contentsOf: file, encoding: .utf8)
            #expect(!text.contains("import Sparkle"), "\(file.lastPathComponent)")
            #expect(!text.contains("import Network"), "\(file.lastPathComponent)")
        }
        let updates = try String(contentsOf: Self.root.appendingPathComponent("Sources/Boris/System/Updates.swift"), encoding: .utf8)
        #expect(updates.contains("sendsSystemProfile = false"))
        #expect(updates.contains("feedParameters(for updater: SPUUpdater, sendingSystemProfile sendingProfile: Bool) -> [[String: String]] {\n        []"))
    }

    @Test("В настройках приложения нет ни адреса ленты, ни профиля системы, ни установки без спроса")
    func infoPlistAsCommitted() throws {
        let data = try Data(contentsOf: Self.root.appendingPathComponent("Resources/Info.plist"))
        let info = try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        // Only a release writes the address in, so a copy built by hand never checks.
        #expect(info["SUFeedURL"] == nil)
        #expect(info["SUPublicEDKey"] == nil)
        #expect(info["SUEnableSystemProfiling"] == nil)
        #expect(info["SUSendProfileInfo"] == nil)
        #expect(info["SUAllowsAutomaticUpdates"] as? Bool == false)
        #expect(info["SUAutomaticallyUpdate"] == nil)
    }

    @Test("Telegram обращается только к своему серверу")
    func telegramGoesOnlyToTelegram() throws {
        let request = try TelegramAPI.request(TelegramLine(subject: "s", text: "t"), token: "1:abc", chat: "1")
        #expect(request.url?.host == "api.telegram.org")
    }

    @Test("Сторонние лицензии лежат в репозитории и называют Sparkle той версии, что подключена")
    func thirdPartyLicenseMatchesThePackage() throws {
        let license = try String(contentsOf: Self.root.appendingPathComponent("THIRD_PARTY_LICENSES.txt"), encoding: .utf8)
        let manifest = try String(contentsOf: Self.root.appendingPathComponent("Package.swift"), encoding: .utf8)
        let pinned = try #require(manifest.firstMatch(of: /Sparkle", exact: "([0-9.]+)"/)?.1)
        #expect(license.contains("Sparkle \(pinned)"))
        #expect(license.contains("Andy Matuschak"))
        #expect(license.contains("Permission is hereby granted"))
    }
}
