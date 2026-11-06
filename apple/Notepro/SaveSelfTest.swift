import AppKit
import SwiftUI

/// `Nebula --save-selftest`: drives the real EditorModel, the real WKWebView and
/// the bundled editor against files in a temp folder, never the user's vault.
/// build-app.sh runs it and refuses a build where any file ends up with the
/// wrong content. Add a case here whenever a new way of losing text turns up.
enum SaveSelfTest {
    private static var failures = 0

    private static func check(_ ok: Bool, _ what: String) {
        print("  \(ok ? "PASS" : "FAIL")  \(what)")
        if !ok { failures += 1 }
    }

    private static func spin(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    private static func wait(_ timeout: TimeInterval = 10, until done: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !done() && Date() < deadline { spin(0.02) }
        return done()
    }

    private static func read(_ url: URL) -> String { (try? String(contentsOf: url, encoding: .utf8)) ?? "<missing>" }

    private static func js(_ model: EditorModel, _ source: String) -> Any? {
        var finished = false
        var value: Any?
        model.hostedWebView?.evaluateJavaScript(source) { result, _ in value = result; finished = true }
        _ = wait { finished }
        return value
    }

    /// Lets queued JS and its "dirty" message land, then saves and waits.
    private static func save(_ model: EditorModel) {
        spin(0.15)
        var finished = false
        model.flushToDisk { _ in finished = true }
        _ = wait { finished }
        spin(0.15)
    }

    private static func type(_ model: EditorModel, _ text: String) {
        _ = js(model, "window.notepro.insertText(\(EditorModel.jsStringLiteral(text))); 0")
        spin(0.15)
    }

    /// A real ⌘Z through the editor's keymap.
    private static func pressUndo(_ model: EditorModel) {
        _ = js(model, """
        document.querySelector('.cm-content').dispatchEvent(new KeyboardEvent('keydown',
          {key:'z', code:'KeyZ', keyCode:90, metaKey:true, bubbles:true, cancelable:true})); 0
        """)
        spin(0.15)
    }

    /// Whatever future bug: the buffer holds `text` though the model still
    /// thinks it holds its file, and the change reads as an edit.
    private static func corruptBuffer(_ model: EditorModel, with text: String) {
        _ = js(model, "window.notepro.setContent(\(EditorModel.jsStringLiteral(text)), true, \(model.loadToken)); 0")
        type(model, "")
        model.handleMessage(["type": "dirty"])
    }

    private static func history(_ root: URL, _ file: URL) -> [String] {
        HistoryStore.list(root: root, for: file).map(HistoryStore.content)
    }

    /// Text that shares nothing with another topic's, like two unrelated notes.
    private static func prose(_ topic: String) -> String {
        var seed = topic.utf8.reduce(UInt64(14_695_981_039_346_656_037)) { ($0 ^ UInt64($1)) &* 1_099_511_628_211 }
        func word() -> String {
            let length = 3 + Int(seed % 6)
            return String((0..<length).map { _ -> Character in
                seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                return Character(UnicodeScalar(UInt8(97 + (seed >> 33) % 26)))
            })
        }
        return (1...12).map { _ in (0..<14).map { _ in word() }.joined(separator: " ") + ".\n" }
            .joined(separator: "\n")
    }

    static func run() -> Never {
        NSApplication.shared.setActivationPolicy(.prohibited)
        // In memory only, so the user's settings are neither read nor changed.
        UserDefaults.standard.setVolatileDomain(["autoSave": true], forName: UserDefaults.argumentDomain)

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("nebula-save-selftest-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        func finish(_ code: Int32) -> Never {   // exit() skips defer
            try? FileManager.default.removeItem(at: root)
            exit(code)
        }

        func file(_ name: String, _ text: String) -> URL {
            let url = root.appendingPathComponent(name)
            try? text.write(to: url, atomically: true, encoding: .utf8)
            return url
        }

        var asked: [SaveGuard.Verdict] = []
        var answer = false
        var held: [String] = []
        SaveGuard.askToReplace = { _, verdict in asked.append(verdict); return answer }
        SaveGuard.reportHeld = { name, _ in held.append(name) }

        let model = EditorModel()
        model.vaultRoot = root
        let host = NSHostingView(rootView: WebView().environmentObject(model))
        host.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()

        let first = file("first.md", prose("derivation"))
        let ready = wait(20) {
            model.open(first)   // deferred until the page is up, then loaded
            spin(0.1)
            return (js(model, "window.notepro && window.notepro.getContent()") as? String) == read(first)
        }
        guard ready else {
            print("  FAIL  the editor didn't start")
            finish(2)
        }

        print("Undo can't leave the document")
        let derivations = first
        let kenyon = file("kenyon.md", prose("kenyon"))
        let physics = file("physics.md", prose("physics"))
        let physicsText = read(physics)
        model.open(kenyon); model.open(physics); spin(0.2)
        pressUndo(model); pressUndo(model); pressUndo(model)
        spin(2.4)  // past the autosave delay
        check(read(physics) == physicsText, "⌘Z ×3 then autosave leaves the file intact")
        check(js(model, "window.notepro.getContent()") as? String == physicsText, "⌘Z ×3 leaves the editor on this file")
        check(!model.isDirty, "⌘Z on a fresh file isn't an edit")

        print("Ordinary editing still saves")
        type(model, "typed here. ")
        save(model)
        check(read(physics).contains("typed here. "), "typed text reaches the file")
        check(read(physics).count > physicsText.count, "nothing else was lost")
        pressUndo(model)
        save(model)
        check(read(physics) == physicsText, "⌘Z still undoes what was typed")
        check(asked.isEmpty, "ordinary edits never ask")

        print("Switching files")
        type(model, "last words. ")
        // The save on leaving runs only if the "dirty" message has arrived, and
        // it lands asynchronously. Wait for the text rather than a fixed time
        // (slow CI machines), and on failure say which of the two went wrong.
        let dirtyAtSwitch = model.isDirty
        let switched = Date()
        model.open(kenyon)
        let reached = wait(5) { read(physics).contains("last words. ") }
        let took = Date().timeIntervalSince(switched)
        check(reached, "unsaved edits reach the file being left")
        if !reached {
            print("        edit registered (isDirty) at switch: \(dirtyAtSwitch); held: \(held); status: \(model.statusText)")
        } else if took > 0.4 {
            print("        note: took \(String(format: "%.2f", took)) s to reach the file")
        }
        check(!read(kenyon).contains("last words. "), "and not the file being opened")
        check(js(model, "window.notepro.getContent()") as? String == read(kenyon), "the editor shows the new file")

        print("Wrong text in the buffer, cause unknown")
        asked = []; answer = false
        let kenyonText = read(kenyon)
        corruptBuffer(model, with: read(derivations))
        save(model)
        check(read(kenyon) == kenyonText, "the file isn't overwritten")
        check(asked == [.matchesOtherFile(derivations)], "the user is asked, naming the other file")
        check(history(root, kenyon).contains(read(derivations)), "the new text is kept in history")
        check(!model.isDirty, "declining counts as resolved")
        check(js(model, "window.notepro.getContent()") as? String == kenyonText, "declining returns the editor to the file")

        asked = []
        corruptBuffer(model, with: prose("something else entirely"))
        spin(2.4)  // the autosave path, not an explicit save
        check(read(kenyon) == kenyonText, "autosave is stopped too, for text matching no other file")
        check(asked == [.replacesDocument], "and the user is asked")

        print("Saving when leaving a file, with nobody to ask")
        asked = []; held = []
        corruptBuffer(model, with: read(derivations))
        model.open(physics); spin(0.4)
        check(read(kenyon) == kenyonText, "the file isn't overwritten")
        check(asked.isEmpty && held == ["kenyon.md"], "the user is told afterwards")
        check(history(root, kenyon).contains(read(derivations)), "the text is kept in history")

        print("A tiny file is protected from another file's text")
        let skeleton = file("01-intro.md", "# Intro\n\n")
        let long = file("dust.md", prose("dust"))
        model.open(long); model.open(skeleton); spin(0.2)
        asked = []; answer = false
        corruptBuffer(model, with: read(long))
        save(model)
        check(read(skeleton) == "# Intro\n\n", "the skeleton isn't overwritten")
        check(asked == [.matchesOtherFile(long)], "the user is asked")

        print("A real replacement goes through when confirmed")
        let rewrite = file("rewrite.md", prose("old draft"))
        let rewriteOriginal = read(rewrite)
        model.open(rewrite); spin(0.2)
        asked = []; answer = true
        corruptBuffer(model, with: prose("new draft"))
        save(model)
        check(read(rewrite) == prose("new draft"), "replacing writes the new text")
        check(history(root, rewrite).contains(rewriteOriginal), "the old version is in history")
        check(asked.count == 1, "asked once")
        type(model, "more. ")
        save(model)
        check(asked.count == 1 && read(rewrite).contains("more. "), "and not again afterwards")
        answer = false

        print("Emptying a file")
        let emptied = file("emptied.md", prose("keep me"))
        let emptiedText = read(emptied)
        model.open(emptied); spin(0.2)
        asked = []
        corruptBuffer(model, with: "")
        save(model)
        check(read(emptied) == emptiedText, "isn't written without asking")
        check(asked == [.replacesDocument], "and asks")

        print("A load that didn't arrive")
        let stale = file("stale.md", prose("stale"))
        let staleText = read(stale)
        model.open(stale); spin(0.2)
        _ = js(model, "window.notepro.setContent(\(EditorModel.jsStringLiteral(read(derivations))), false, -1); 0")
        model.handleMessage(["type": "dirty"])
        asked = []
        var saved = true
        model.flushToDisk { saved = $0 }
        spin(0.5)
        check(read(stale) == staleText, "the buffer's text isn't written")
        check(!saved, "the save reports failure rather than success")
        check(model.isDirty, "and stays unsaved")
        _ = js(model, "window.notepro.setContent(\(EditorModel.jsStringLiteral(staleText)), false, \(model.loadToken)); 0")
        spin(2.4)
        model.open(stale); spin(0.2)

        print("History backs up before the first overwrite")
        let fresh = file("fresh.md", prose("fresh"))
        let freshText = read(fresh)
        model.open(fresh); spin(0.2)
        check(history(root, fresh).isEmpty, "a file that was only opened has no history yet")
        type(model, "first edit. ")
        save(model)
        check(history(root, fresh).contains(freshText), "the first save keeps the original")

        print("A burst of autosaves can't push out the last good version")
        let now = Date()
        let old = now.addingTimeInterval(-40 * 86_400)
        let burst = (0..<500).map { now.addingTimeInterval(-Double($0) * 2) }
        let kept = HistoryStore.retained(burst + [old], now: now)
        check(kept.contains(old), "a 40-day-old version survives 500 new saves")
        check(burst.prefix(60).allSatisfy(kept.contains), "the newest 60 are all there")
        let thin = HistoryStore.retained((0..<5000).map { now.addingTimeInterval(-Double($0) * 1800) }, now: now)
        check(thin.count < 60 + 7 * 24 + 110, "older versions are thinned")

        print("Guard thresholds")
        let doc = prose("threshold")
        check(SaveGuard.verdict(disk: nil, proposed: doc, target: fresh, loaded: [:]) == .safe, "a new file is safe")
        check(SaveGuard.verdict(disk: doc, proposed: doc, target: fresh, loaded: [:]) == .safe, "no change is safe")
        check(SaveGuard.verdict(disk: doc, proposed: String(doc.prefix(doc.count / 2)), target: fresh, loaded: [:]) == .safe,
              "deleting half a note is an edit")
        check(SaveGuard.verdict(disk: "short", proposed: "other", target: fresh, loaded: [:]) == .safe,
              "very short notes can be rewritten freely")
        let oneLong = String(repeating: "一段很長而且沒有換行的中文段落 with words, ", count: 30)
        check(SaveGuard.verdict(disk: oneLong, proposed: oneLong + "再多一句。", target: fresh, loaded: [:]) == .safe,
              "editing a single long paragraph is an edit")

        print(failures == 0 ? "\nSave self-test passed." : "\nSave self-test FAILED: \(failures) check(s).")
        finish(failures == 0 ? 0 : 1)
    }
}
