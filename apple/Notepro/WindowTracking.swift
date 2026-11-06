import SwiftUI
import AppKit

/// Which main window the user was last working in. Commands are posted
/// app-wide (sidebar actions, the palette, inserts from the PDF reader) and
/// every open main window listens — without this, "open to the side" in one
/// window would split all of them. "Last" rather than "key" so a command sent
/// from a PDF reader window still lands in the note window behind it.
enum MainWindowFocus {
    static var current: UUID?
    static func isCurrent(_ id: UUID) -> Bool { current == nil || current == id }
}

/// Hands over the hosting NSWindow and marks it current whenever it becomes key.
struct MainWindowTracker: NSViewRepresentable {
    let id: UUID
    let onWindow: (NSWindow) -> Void
    /// The window is about to close — save what's unsaved.
    let onClose: () -> Void

    func makeNSView(context: Context) -> NSView { TrackingView(id: id, onWindow: onWindow, onClose: onClose) }
    func updateNSView(_ nsView: NSView, context: Context) {}

    final class TrackingView: NSView {
        private let id: UUID
        private let onWindow: (NSWindow) -> Void
        private let onClose: () -> Void
        private var tokens: [NSObjectProtocol] = []

        init(id: UUID, onWindow: @escaping (NSWindow) -> Void, onClose: @escaping () -> Void) {
            self.id = id; self.onWindow = onWindow; self.onClose = onClose
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            tokens.forEach(NotificationCenter.default.removeObserver)
            tokens = []
            guard let w = window else { return }
            onWindow(w)
            if w.isKeyWindow || MainWindowFocus.current == nil { MainWindowFocus.current = id }
            let id = self.id
            let onClose = self.onClose
            tokens.append(NotificationCenter.default.addObserver(
                forName: NSWindow.didBecomeKeyNotification, object: w, queue: .main
            ) { _ in MainWindowFocus.current = id })
            // A closed window must not keep the title: commands would go nowhere.
            tokens.append(NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification, object: w, queue: .main
            ) { _ in
                onClose()
                if MainWindowFocus.current == id { MainWindowFocus.current = nil }
            })
        }

        deinit { tokens.forEach(NotificationCenter.default.removeObserver) }
    }
}

/// The value a main window is opened with: a fresh identity (so openWindow
/// always spawns a new window), plus optionally a file to show in it.
struct MainWindowSeed: Codable, Hashable {
    var id = UUID()
    var url: URL?
}
