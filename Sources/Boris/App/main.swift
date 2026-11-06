import AppKit
import BorisData

// A release build has no check modes. Started for a check, it would be the real app on the person's screen.
#if !DEBUG
if let stray = BorisPaths.checkVariable(in: ProcessInfo.processInfo.environment) {
    FileHandle.standardError.write(Data("A release build knows no check modes and \(stray) is set, so it does not start.\n".utf8))
    exit(2)
}
#endif

let launch = LaunchCoordinator()
guard DevSnapshot.isRequested || DevSnapshot.ignoresOtherCopies || launch.claimInstance() else { exit(0) }

let app = NSApplication.shared
let delegate = AppDelegate(launch: launch)
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
