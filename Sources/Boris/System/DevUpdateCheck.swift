#if DEBUG
import AppKit
import Foundation
import Sparkle

/// `BORIS_SNAPSHOT=/folder BORIS_UPDATE_CHECK=url` runs the real Sparkle against an appcast at that address and prints what came of it.
/// `scripts/check-network.py` starts a server of its own and looks at what Sparkle asked it. The app here is a made-up one in that folder,
/// nothing is shown, and nothing is ever downloaded or installed. `BORIS_UPDATE_CHECK_AUTOMATIC=1` lets Sparkle's own schedule start the check.
@MainActor
enum DevUpdateCheck {
    /// Sparkle's interface with nothing in it.
    private final class SilentDriver: NSObject, SPUUserDriver {
        func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
            reply(SUUpdatePermissionResponse(automaticUpdateChecks: false, automaticUpdateDownloading: false, sendSystemProfile: false))
        }
        func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {}
        func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) {
            reply(.dismiss)
        }
        func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}
        func showUpdateReleaseNotesFailedToDownloadWithError(_ error: any Error) {}
        func showUpdateNotFoundWithError(_ error: any Error, acknowledgement: @escaping () -> Void) { acknowledgement() }
        func showUpdaterError(_ error: any Error, acknowledgement: @escaping () -> Void) { acknowledgement() }
        func showDownloadInitiated(cancellation: @escaping () -> Void) {}
        func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {}
        func showDownloadDidReceiveData(ofLength length: UInt64) {}
        func showDownloadDidStartExtractingUpdate() {}
        func showExtractionReceivedProgress(_ progress: Double) {}
        func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) { reply(.dismiss) }
        func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) {}
        func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) { acknowledgement() }
        func dismissUpdateInstallation() {}
    }

    private static func madeUpApp(in folder: String, feed: String, automatic: Bool) -> Bundle? {
        let app = URL(fileURLWithPath: folder).appendingPathComponent("Check.app")
        let contents = app.appendingPathComponent("Contents")
        try? FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let info: [String: Any] = [
            "CFBundleIdentifier": "app.boris.check",
            "CFBundleName": "Check",
            "CFBundleExecutable": "Check",
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": "0.1.0",
            "CFBundleVersion": "1",
            "SUFeedURL": feed,
            // Thirty-two zero bytes, which no real key is: no update could ever pass with it.
            "SUPublicEDKey": Data(count: 32).base64EncodedString(),
            "SUEnableAutomaticChecks": automatic,
            "SUAllowsAutomaticUpdates": false,
        ]
        guard let data = try? PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0) else { return nil }
        try? data.write(to: contents.appendingPathComponent("Info.plist"))
        return Bundle(url: app)
    }

    static func runIfRequested() -> Bool {
        let environment = ProcessInfo.processInfo.environment
        guard let feed = environment["BORIS_UPDATE_CHECK"], let folder = environment["BORIS_SNAPSHOT"] else { return false }
        let automatic = environment["BORIS_UPDATE_CHECK_AUTOMATIC"] == "1"
        guard let host = madeUpApp(in: folder, feed: feed, automatic: automatic) else { exit(2) }
        let engine = SparkleEngine(host: host, driver: SilentDriver())
        let updates = Updates(engine: engine)

        Task { @MainActor in
            updates.start()
            var cycle: SPUUpdateCheck?
            var failed = false
            engine.onCycleFinished = { check, error in
                cycle = check
                failed = error != nil
            }
            if !automatic { updates.checkNow() }
            let end = Date().addingTimeInterval(60)
            while cycle == nil, Date() < end { try? await Task.sleep(for: .milliseconds(100)) }
            var version = ""
            if case .available(let offer) = updates.status { version = offer.version }
            print(#"{"started":\#(updates.canCheck),"cycle":"\#(cycle.map { $0 == .updatesInBackground ? "automatic" : "person" } ?? "none")","error":\#(failed),"status":"\#(word(updates.status))","version":"\#(version)","sendsProfile":\#(engine.sendsProfile)}"#)
            fflush(stdout)
            exit(0)
        }
        return true
    }

    private static func word(_ status: UpdateStatus) -> String {
        switch status {
        case .unknown: return "unknown"
        case .checking: return "checking"
        case .upToDate: return "upToDate"
        case .available: return "available"
        case .unreachable: return "unreachable"
        }
    }
}
#endif
