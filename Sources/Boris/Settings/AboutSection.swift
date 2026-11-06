import AppKit
import BorisCore
import SwiftUI

/// The link and the texts of the section, apart from the view. Neither of them ever goes to the network: the texts are inside the app, and the link is only handed to the browser.
enum AboutContent {
    /// Set in the app's Info.plist. Without a link there is no button. Only a web page counts, so that a mistake in the file cannot start anything else.
    static func coffeeLink(info: String?, override: String? = nil) -> URL? {
        guard let text = override ?? info, !text.isEmpty, let link = URL(string: text), link.scheme == "https" || link.scheme == "http", link.host != nil else { return nil }
        return link
    }

    static func text(_ license: AboutSection.LicenseText, in bundle: Bundle = .main) -> String? {
        license.text(in: bundle)
    }

    /// License files are broken into lines for a terminal, which in a narrower window leaves a word or two alone on every other line.
    /// So the lines of a paragraph are joined for showing. Indented lines are lists, and stay as they are.
    static func flowing(_ text: String) -> String {
        var result: [String] = []
        for line in text.components(separatedBy: "\n") {
            let continues = result.last.map { !$0.isEmpty && !$0.hasPrefix(" ") } ?? false
            if continues, !line.isEmpty, !line.hasPrefix(" ") {
                result[result.count - 1] += " " + line
            } else {
                result.append(line)
            }
        }
        return result.joined(separator: "\n")
    }
}

/// What Boris is, who made it and on what terms.
struct AboutSection: View {
    @Bindable var model: AppModel
    @State private var license: LicenseText?
    private let coffeeLink: URL?
    private let openLink: (URL) -> Void

    /// - Parameter openLink: hands a link to the browser. Boris itself does not go to it.
    init(model: AppModel, license: LicenseText? = nil, coffeeLink: URL? = AboutSection.configuredCoffeeLink, openLink: @escaping (URL) -> Void = { NSWorkspace.shared.open($0) }) {
        self.model = model
        _license = State(initialValue: license)
        self.coffeeLink = coffeeLink
        self.openLink = openLink
    }

    /// Both texts lie inside the app: `scripts/build-app.sh` puts them there, and looking at them never reaches for the network.
    enum LicenseText {
        case own, thirdParty

        var fileName: String {
            switch self {
            case .own: return "LICENSE"
            case .thirdParty: return "THIRD_PARTY_LICENSES"
            }
        }

        func text(in bundle: Bundle = .main) -> String? {
            bundle.url(forResource: fileName, withExtension: "txt").flatMap { try? String(contentsOf: $0, encoding: .utf8) }
        }

        /// License files are wrapped at 80 columns, which breaks again at the edge of any narrower window. So on screen a paragraph flows,
        /// while short lines, lists and rules stay as they are. «Copy» still gives the file as it is.
        static func flowing(_ text: String) -> String {
            var lines: [String] = []
            for line in text.components(separatedBy: "\n") {
                let bare = line.trimmingCharacters(in: .whitespaces)
                if let last = lines.last, last.count >= 60, !bare.isEmpty, !isRule(last), !isRule(bare), bare.firstMatch(of: #/^[0-9]+\. /#) == nil {
                    lines[lines.count - 1] = last.trimmingCharacters(in: .whitespaces) + " " + bare
                } else {
                    lines.append(line)
                }
            }
            return lines.joined(separator: "\n")
        }

        private static func isRule(_ line: String) -> Bool {
            line.allSatisfy { $0 == "=" || $0 == "-" }
        }
    }

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? BorisCore.version
    }

    static var configuredCoffeeLink: URL? {
        var override: String?
        #if DEBUG
        override = ProcessInfo.processInfo.environment["BORIS_COFFEE_URL"]
        #endif
        return AboutContent.coffeeLink(info: Bundle.main.object(forInfoDictionaryKey: "BorisCoffeeURL") as? String, override: override)
    }

    var body: some View {
        if let license {
            licenseView(license)
        } else {
            about
        }
    }

    private var credits: [(role: String, name: String)] {
        [
            (L("Walrus in the leading role"), L("Boris")),
            (L("Cigar"), L("Still lit, somehow")),
            (L("Monocle"), L("On a chain, just in case")),
            (L("Gold crown"), L("Paid in full")),
            (L("Reading your files"), L("Only reading, honest")),
            (L("Night shift"), L("Everyone who should be asleep")),
        ]
    }

    private var about: some View {
        ScrollView {
            VStack(spacing: 14) {
                VStack(spacing: 2) {
                    WalrusView(pose: .watch, outfit: model.outfit, size: 120)
                    Text(verbatim: "Boris").font(.system(size: 20, weight: .bold)).padding(.top, 6)
                    Text(L("Version %@", version)).font(.system(size: 12)).foregroundStyle(Palette.text2)
                }
                Text(L("Boris shows all your work with Claude in one place: what the agents are doing, what it costs, what broke and who is waiting for an answer. It runs on your Mac, with no account."))
                    .font(.system(size: 13))
                    .lineSpacing(4)
                    .foregroundStyle(Palette.text2)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 440)
                    .fixedSize(horizontal: false, vertical: true)
                VStack(spacing: 0) {
                    row(L("Author"), L("Igor Bogdanov"))
                    divider
                    linkRow(L("License"), L("Code: MIT. The walrus, his lines and sounds: all rights reserved.")) { license = .own }
                    divider
                    linkRow(L("Third-party licenses"), L("The libraries Boris is built with")) { license = .thirdParty }
                    divider
                    row(L("With thanks"), L("anhyobin, for Claude Code Monitor"))
                }
                .background(RoundedRectangle(cornerRadius: DesignMetrics.radiusLarge).fill(Palette.fill1))
                VStack(spacing: 2) {
                    ForEach(credits, id: \.role) { credit in
                        (Text(verbatim: "\(credit.role): ").foregroundStyle(Palette.text3) + Text(credit.name).foregroundStyle(Palette.text1))
                            .font(.system(size: 12))
                    }
                }
                if let coffeeLink {
                    Button {
                        openLink(coffeeLink)
                    } label: {
                        Label(L("Buy Boris a coffee"), systemImage: "cup.and.saucer")
                            .font(.system(size: 12.5))
                            .padding(.horizontal, 14)
                            .frame(height: 28)
                            .background(Capsule().fill(Palette.button))
                            .overlay(Capsule().strokeBorder(Palette.buttonBorder, lineWidth: 0.5))
                    }
                    .buttonStyle(.plain)
                }
                Text(L("Boris is not affiliated with Anthropic.")).font(.system(size: 11)).foregroundStyle(Palette.text3)
            }
            .padding(EdgeInsets(top: 30, leading: 36, bottom: 16, trailing: 36))
            .frame(maxWidth: .infinity)
        }
    }

    private var divider: some View {
        Rectangle().fill(Palette.separator).frame(height: 1)
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title).foregroundStyle(Palette.text2).frame(width: 130, alignment: .leading)
            Text(value).frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 12.5))
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func linkRow(_ title: String, _ value: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 0) {
                row(title, value)
                Text(verbatim: "›").foregroundStyle(Palette.text3).padding(.trailing, 12)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func text(_ license: LicenseText) -> String {
        license.text() ?? L("The text is missing from this build.")
    }

    private func licenseView(_ shown: LicenseText) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button(L("‹ About Boris")) { license = nil }.buttonStyle(PlainActionStyle())
                Text(shown == .own ? L("License") : L("Third-party licenses")).font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 0)
                Button(L("Copy")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text(shown), forType: .string)
                }
                .buttonStyle(PlainActionStyle())
            }
            .padding(EdgeInsets(top: 30, leading: 20, bottom: 12, trailing: 20))
            Rectangle().fill(Palette.separator).frame(height: 1)
            ScrollView {
                Text(LicenseText.flowing(text(shown)))
                    .font(.system(size: 11.5, design: .monospaced))
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(EdgeInsets(top: 16, leading: 24, bottom: 20, trailing: 24))
            }
        }
    }
}
