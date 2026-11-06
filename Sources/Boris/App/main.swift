import AppKit

// Before anything else: a debug build that was not asked to run leaves here, with no window, no connection to the screen and no defaults touched.
// Giving way to other copies comes after this, because otherwise a running copy would decide how this one ends.
guard DevSnapshot.mayRun else {
    FileHandle.standardError.write(Data("This debug build was not asked to run, so it stops here. It starts as the real app only with BORIS_ALLOW_UI=1.\n".utf8))
    exit(2)
}

let launch = LaunchCoordinator()
guard DevSnapshot.isRequested || DevSnapshot.ignoresOtherCopies || launch.claimInstance() else { exit(0) }

let app = NSApplication.shared
let delegate = AppDelegate(launch: launch)
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
