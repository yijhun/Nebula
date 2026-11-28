import SwiftUI
import AppKit

/// Where a Dock icon or a `nebula://` link takes you. Nebula has two Dock
/// icons: Nebula itself (notes) and the small "Nebula Papers" launcher
/// (apple/Launcher), which hands its click to this app as `nebula://library`,
/// or starts it with `--open-library`. Paper links (`nebula://paper/<key>`,
/// the chat's citations) open from other apps too.
enum AppRoute: Equatable {
    case notes, library
    case paper(URL)

    /// `nebula://library`, `nebula://notes` (also `nebula:library`),
    /// `nebula://paper/<citekey>?page=N&quote=…`.
    init?(url: URL) {
        guard url.scheme?.lowercased() == "nebula" else { return nil }
        let name = (url.host ?? url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))).lowercased()
        switch name {
        case "library": self = .library
        case "notes": self = .notes
        case "paper" where ReaderSession.parse(url) != nil: self = .paper(url)
        default: return nil
        }
    }
}

/// Opens the notes window or the reader's library from AppKit code (the Dock,
/// URL events). SwiftUI opens scenes only through a view's `openWindow`, so
/// the first window that appears hands it over.
@MainActor
enum AppWindows {
    static var openWindow: OpenWindowAction?
    /// A route asked for before any window could open it: `--open-library`
    /// at launch, or a `nebula://` link that started the app.
    static var pendingRoute: AppRoute?
    /// Every main (notes) window, so the Dock icon can bring one forward.
    static let mainWindows = NSHashTable<NSWindow>.weakObjects()
    /// The launch window (by its RootView id) appeared before its NSWindow
    /// did; close it when that arrives.
    static var closeLaunchWindow: UUID?

    static func go(_ route: AppRoute) {
        guard openWindow != nil else {
            // No window has appeared yet. Launched by a link, SwiftUI opens
            // none at all; ask it for its usual first window, which then
            // carries the route out (windowAppeared).
            pendingRoute = route
            DispatchQueue.main.async {
                if openWindow == nil { _ = NSApp.delegate?.applicationOpenUntitledFile?(NSApp) }
            }
            return
        }
        switch route {
        case .library: showLibrary()
        case .notes: showNotes()
        case .paper(let url):
            ReaderSession.shared.openLink(url)
            openWindow?(id: "reader")
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    static func showLibrary() {
        // Before the window opens, so the last paper is not loaded (and
        // marked opened) on the way to the library.
        ReaderSession.shared.showLibrary = true
        ReaderSession.shared.requestQuickOpen = true      // library tab, search focused
        openWindow?(id: "reader")
        NSApp.activate(ignoringOtherApps: true)
    }

    /// The frontmost notes window, else a new one.
    static func showNotes() {
        let mine = mainWindows.allObjects
        let front = NSApp.orderedWindows.first { w in mine.contains(w) && w.isVisible }
        if let w = front ?? mine.first(where: \.isMiniaturized) ?? mine.first(where: \.isVisible) {
            if w.isMiniaturized { w.deminiaturize(nil) }
            w.makeKeyAndOrderFront(nil)
        } else {
            openWindow?(id: "main", value: MainWindowSeed())
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Called as each window appears: keep `openWindow`, and carry out a
    /// route that was waiting for it. Returns true when that route was the
    /// library or a paper, so the launch window can step aside for the reader.
    @discardableResult
    static func windowAppeared(_ open: OpenWindowAction) -> Bool {
        openWindow = open
        guard let route = pendingRoute else { return false }
        pendingRoute = nil
        go(route)
        return route != .notes
    }
}

