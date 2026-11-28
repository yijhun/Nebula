import AppKit

// Nebula Papers: a second Dock icon for Nebula that opens the reader's
// library. It is not a second app: it asks Nebula (bundle id in its
// Info.plist) for nebula://library, or starts Nebula with --open-library,
// then quits. LSUIElement keeps it out of the Dock while it runs.

let info = Bundle.main.infoDictionary ?? [:]
let target = info["NebulaTargetBundleID"] as? String ?? "com.notepro.app"
let route = URL(string: "nebula://library")!

/// The Nebula.app next to this launcher (build-app.sh puts them side by
/// side), else wherever Launch Services knows one.
func nebulaApp() -> URL? {
    let sibling = Bundle.main.bundleURL.deletingLastPathComponent()
        .appendingPathComponent(info["NebulaTargetApp"] as? String ?? "Nebula.app")
    if Bundle(url: sibling)?.bundleIdentifier == target { return sibling }
    return NSWorkspace.shared.urlForApplication(withBundleIdentifier: target)
}

func finish(_ error: Error?) -> Never {
    if let error { FileHandle.standardError.write("Nebula Papers: \(error.localizedDescription)\n".data(using: .utf8)!) }
    exit(error == nil ? 0 : 1)
}

let config = NSWorkspace.OpenConfiguration()
config.activates = true
if let running = NSRunningApplication.runningApplications(withBundleIdentifier: target).first,
   let url = running.bundleURL {
    // Opening a URL, not the app: reopening the app would mean "notes".
    NSWorkspace.shared.open([route], withApplicationAt: url, configuration: config) { _, e in finish(e) }
} else if let app = nebulaApp() {
    config.arguments = ["--open-library"]
    NSWorkspace.shared.openApplication(at: app, configuration: config) { _, e in finish(e) }
} else {
    finish(NSError(domain: "Nebula Papers", code: 1,
                   userInfo: [NSLocalizedDescriptionKey: "Nebula.app (\(target)) not found"]))
}
DispatchQueue.main.asyncAfter(deadline: .now() + 15) { exit(1) }
dispatchMain()
