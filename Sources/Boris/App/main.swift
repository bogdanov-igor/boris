import AppKit

let launch = LaunchCoordinator()
guard DevSnapshot.isRequested || DevSnapshot.ignoresOtherCopies || launch.claimInstance() else { exit(0) }

let app = NSApplication.shared
let delegate = AppDelegate(launch: launch)
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
