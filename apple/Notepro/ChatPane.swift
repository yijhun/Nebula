import SwiftUI
import WebKit

/// The VS Code–style chat panel: a web UI (web-core `chat.html`, reusing the
/// note preview renderer so replies show real maths/charts/TikZ) driving a
/// subscription CLI through `AgentSession`. One shared controller per app, so
/// hiding the panel keeps the conversation.
@MainActor
final class ChatController: NSObject, ObservableObject, WKScriptMessageHandler {
    static let shared = ChatController()

    /// Held strongly (the controller is app-lifetime) so the rendered chat
    /// survives the pane being hidden and shown again.
    var webView: WKWebView?
    /// Supplied by the window: vault root + the editor the user is looking at.
    var context: () -> (vault: URL?, editor: EditorModel?) = { (nil, nil) }

    private var session: AgentSession?
    private var mode: AgentSession.Mode = .edit
    /// "" = the CLI's default model.
    private var model = ""

    private let accounts = AIAccountStore.shared
    private var ready = false
    /// Files dropped on the panel, offered to the next message.
    private var attachments: [URL] = []
    /// Transcript + CLI session id per account, so a conversation survives
    /// switching panes, closing the sidebar and quitting the app.
    private var saved: [String: [String: Any]] = [:]
    private var saveWork: DispatchWorkItem?

    // MARK: JS → Swift

    func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        switch type {
        case "ready":
            ready = true
            loadSaved()
            accounts.seedInstalledLogins()
            accounts.refreshAll()
            pushState()
            restoreTranscript()
            // Status checks are async — push again once they've landed.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in self?.pushState() }
        case "send":
            send(text: body["text"] as? String ?? "",
                 attachNote: body["attachNote"] as? Bool ?? false,
                 attachSelection: body["attachSelection"] as? Bool ?? false)
        case "stop":
            session?.stop()
        case "newChat":
            attachments = []
            if let key = accounts.active?.id.uuidString { saved[key] = nil; writeSaved() }
            restart(resume: false)
            emit(["type": "nebula", "event": "cleared"])
            pushState()
        case "setMode":
            mode = (body["mode"] as? String) == "plan" ? .readOnly : .edit
            if session != nil { restart(resume: true) }
            pushState()
        case "setModel":
            model = body["model"] as? String ?? ""
            if session != nil { restart(resume: true) }
            pushState()
        case "switchAccount":
            if let s = body["id"] as? String, let id = UUID(uuidString: s) {
                accounts.activeID = id
                attachments = []
                // Each account keeps its own conversation; bring that one back
                // rather than throwing the previous one away.
                restart(resume: false)
                emit(["type": "nebula", "event": "cleared"])
                pushState()
                restoreTranscript()
            }
        case "addAccount":
            let provider: AIAccount.Provider = (body["provider"] as? String) == "codex" ? .codex : .claude
            if provider == .codex, AIAccountStore.codexPath == nil {
                emitNotice("尚未安裝 Codex CLI — 安裝後才能加入 ChatGPT 帳號")
                return
            }
            let a = accounts.add(provider: provider, label: body["label"] as? String ?? "")
            accounts.activeID = a.id
            restart(resume: false)
            pushState()
        case "login":
            if let s = body["id"] as? String, let id = UUID(uuidString: s) { accounts.login(id) }
        case "refreshAccounts":
            accounts.refreshAll()
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in self?.pushState() }
        case "removeAccount":
            if let s = body["id"] as? String, let id = UUID(uuidString: s) {
                let wasActive = accounts.activeID == id
                accounts.remove(id)
                if wasActive { restart(resume: false); emit(["type": "nebula", "event": "cleared"]) }
                pushState()
            }
        case "persist":
            if let items = body["items"] as? [[String: Any]] { persist(items: items) }
        case "clearAttachments":
            attachments = []; pushState()
        case "removeAttachment":
            if let p = body["path"] as? String { attachments.removeAll { $0.path == p }; pushState() }
        case "addFiles":
            pickFiles(dirs: body["dirs"] as? Bool ?? false)
        case "openFile":
            if let path = body["path"] as? String { openInEditor(path) }
        case "revertEdit":
            revertEdit(path: body["path"] as? String ?? "",
                       oldString: body["oldString"] as? String ?? "",
                       newString: body["newString"] as? String ?? "",
                       editID: body["editID"] as? String ?? "")
        default: break
        }
    }

    // MARK: session

    private func ensureSession() -> Bool {
        if let s = session, s.isRunning { return true }
        if session == nil, let rid = restoredSessionID, !rid.isEmpty {
            restoredSessionID = nil
            return restart(resume: true, forcedResumeID: rid)
        }
        return restart(resume: session?.sessionID != nil)
    }

    @discardableResult
    private func restart(resume: Bool, forcedResumeID: String? = nil) -> Bool {
        let old = session
        let resumeID = forcedResumeID ?? (resume ? old?.sessionID : nil)
        old?.onExit = nil; old?.onLine = nil
        old?.stop()
        session = nil
        guard let acct = accounts.active else { return false }
        let cwd = context().vault ?? URL(fileURLWithPath: NSHomeDirectory())
        grantedDirs = extraDirs(for: cwd)
        let s = AgentSession(account: acct, cwd: cwd, mode: mode,
                             model: model.isEmpty ? nil : model, resumeID: resumeID,
                             extraDirs: grantedDirs)
        s.onLine = { [weak self] line in self?.forward(line) }
        s.onExit = { [weak self] code, err in
            guard let self, self.session === s else { return }
            self.emit(["type": "nebula", "event": "exited", "code": Int(code), "stderr": err])
        }
        if let err = s.start() {
            emitNotice(err)
            return false
        }
        session = s
        return true
    }

    private func send(text: String, attachNote: Bool, attachSelection: Bool) {
        let ctx = context()
        var prompt = text
        var extras: [String] = []
        if attachNote, let editor = ctx.editor, let url = editor.currentURL {
            editor.saveIfDirty()                         // Claude reads the file from disk
            let rel = ctx.vault.map { url.path.replacingOccurrences(of: $0.path + "/", with: "") } ?? url.path
            extras.append("（目前開啟的筆記：\(rel)）")
        }
        if !attachments.isEmpty {
            let list = attachments.map { u in
                Self.isDirectory(u) ? "- \(u.path)/  （資料夾，可用 Glob/Grep 瀏覽）" : "- \(u.path)"
            }.joined(separator: "\n")
            extras.append("附加的檔案／資料夾（用 Read 開檔，PDF 也讀得了；資料夾用 Glob 列出內容）：\n\(list)")
        }
        let finish = { [weak self] (selection: String) in
            guard let self else { return }
            if !selection.isEmpty { extras.append("選取的內容：\n```\n\(selection)\n```") }
            if !extras.isEmpty { prompt += "\n\n" + extras.joined(separator: "\n\n") }
            // Files outside the vault need the CLI to be granted their folder,
            // which is fixed at spawn time — restart when the set has grown.
            if self.needsRestartForAttachments() { self.restart(resume: true) }
            guard self.ensureSession() else { return }
            self.session?.send(prompt)
            self.attachments = []
            self.pushState()
        }
        if attachSelection, let editor = ctx.editor {
            editor.getCoworkPayload(scope: "selection") { finish($0) }
        } else {
            finish("")
        }
    }

    // MARK: edits

    /// Undo one Edit-tool change by applying it in reverse (new → old), after
    /// snapshotting the current file so the undo itself is undoable.
    private func revertEdit(path: String, oldString: String, newString: String, editID: String) {
        let url = resolve(path)
        guard let cur = try? String(contentsOf: url, encoding: .utf8) else {
            emitNotice("還原失敗：讀不到檔案"); return
        }
        guard !newString.isEmpty, let r = cur.range(of: newString) else {
            emitNotice("還原失敗：檔案已被改動，找不到那段修改（可從版本歷史還原）"); return
        }
        HistoryStore.snapshot(root: context().vault, file: url, content: cur)
        let updated = cur.replacingCharacters(in: r, with: oldString)
        do {
            try updated.write(to: url, atomically: true, encoding: .utf8)
            emit(["type": "nebula", "event": "reverted", "editID": editID])
        } catch {
            emitNotice("還原失敗：\(error.localizedDescription)")
        }
    }

    private func resolve(_ path: String) -> URL {
        if path.hasPrefix("/") { return URL(fileURLWithPath: path) }
        return (context().vault ?? URL(fileURLWithPath: NSHomeDirectory())).appendingPathComponent(path)
    }

    private func openInEditor(_ path: String) {
        let url = resolve(path)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        context().editor?.open(url)
    }

    // MARK: Swift → JS

    private func forward(_ line: String) {
        webView?.evaluateJavaScript("window.nebulaChat && window.nebulaChat.onEvent(\(Self.js(line)))")
    }

    private func emit(_ obj: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: obj),
              let s = String(data: data, encoding: .utf8) else { return }
        forward(s)
    }

    private func emitNotice(_ text: String) { emit(["type": "nebula", "event": "notice", "text": text]) }

    func pushState() {
        guard ready else { return }
        let list: [[String: Any]] = accounts.accounts.map { a in
            ["id": a.id.uuidString, "provider": a.provider.rawValue, "label": a.label,
             "subtitle": a.subtitle, "loggedIn": a.loggedIn,
             "isDefault": a.configDir == nil]
        }
        let state: [String: Any] = [
            "accounts": list,
            "activeID": accounts.active?.id.uuidString ?? "",
            "mode": mode == .readOnly ? "plan" : "acceptEdits",
            "model": model,
            "models": Self.models(for: accounts.active?.provider ?? .claude),
            "codexInstalled": AIAccountStore.codexPath != nil,
            "vault": context().vault?.lastPathComponent ?? "",
            "lang": currentlyEnglish() ? "en" : "zh",
            "attachments": attachments.map {
                ["path": $0.path, "name": $0.lastPathComponent, "isDir": Self.isDirectory($0)]
            },
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: state),
              let s = String(data: data, encoding: .utf8) else { return }
        webView?.evaluateJavaScript("window.nebulaChat && window.nebulaChat.setState(\(Self.js(s)))")
    }

    // MARK: attachments

    /// Folders the CLI must be allowed to read, for attachments that live
    /// outside the vault (Zotero's storage, Downloads, …).
    private var grantedDirs: [String] = []

    private func extraDirs(for vault: URL) -> [String] {
        let root = vault.standardizedFileURL.path
        var dirs = Set(grantedDirs)
        for f in attachments {
            // A folder grants itself; a file grants the folder holding it.
            let d = (Self.isDirectory(f) ? f : f.deletingLastPathComponent())
                .standardizedFileURL.path
            if d != root, !d.hasPrefix(root + "/") { dirs.insert(d) }
        }
        return dirs.sorted()
    }

    private func needsRestartForAttachments() -> Bool {
        let cwd = context().vault ?? URL(fileURLWithPath: NSHomeDirectory())
        return extraDirs(for: cwd) != grantedDirs
    }

    static func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    func addAttachments(_ urls: [URL]) {
        for u in urls where !attachments.contains(u) { attachments.append(u) }
        pushState()
    }

    /// One panel per kind. Offering files and folders in the same panel makes
    /// double-clicking a folder navigate into it rather than choose it, so
    /// folders looked unsupported even though they were not.
    private func pickFiles(dirs: Bool) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = !dirs
        panel.canChooseDirectories = dirs
        panel.allowsMultipleSelection = true
        panel.prompt = LZ("附加")
        if dirs { panel.message = LZ("選擇資料夾") }
        guard panel.runModal() == .OK else { return }
        addAttachments(panel.urls)
    }

    // MARK: transcript persistence

    private var savedFile: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Nebula", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("chats.json")
    }

    private func loadSaved() {
        guard let data = try? Data(contentsOf: savedFile),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Any]]
        else { return }
        saved = obj
    }

    private func writeSaved() {
        guard let data = try? JSONSerialization.data(withJSONObject: saved) else { return }
        try? data.write(to: savedFile)
    }

    /// The UI sends its transcript whenever it changes; store it against the
    /// active account together with the CLI session id so the next message can
    /// resume the real conversation, not just show old text.
    private func persist(items: [[String: Any]]) {
        guard let key = accounts.active?.id.uuidString else { return }
        saved[key] = ["items": items, "sessionID": session?.sessionID ?? saved[key]?["sessionID"] as? String ?? ""]
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.writeSaved() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
    }

    /// Put the stored transcript back on screen and line the CLI up to resume it.
    private func restoreTranscript() {
        guard let key = accounts.active?.id.uuidString, let entry = saved[key],
              let items = entry["items"] as? [[String: Any]], !items.isEmpty else { return }
        restoredSessionID = entry["sessionID"] as? String
        emit(["type": "nebula", "event": "restore", "items": items])
    }

    /// Session id of the restored conversation, used on the next send.
    private var restoredSessionID: String?

    /// Codex model names, read from the CLI's own cache/config so the list
    /// matches whatever that account actually has (falls back to the configured
    /// model alone). Refreshed lazily; cheap file reads.
    private static var codexModels: [String] {
        let home = "\(NSHomeDirectory())/.codex"
        var found = Set<String>()
        let fm = FileManager.default
        if let items = try? fm.contentsOfDirectory(atPath: home) {
            for f in items where f.hasSuffix(".json") || f.hasSuffix(".toml") {
                guard let text = try? String(contentsOfFile: "\(home)/\(f)", encoding: .utf8) else { continue }
                let re = try? NSRegularExpression(pattern: #""(gpt-[0-9][A-Za-z0-9._-]{0,24})""#)
                let ns = text as NSString
                re?.matches(in: text, range: NSRange(location: 0, length: ns.length)).forEach {
                    found.insert(ns.substring(with: $0.range(at: 1)))
                }
            }
        }
        return found.sorted()
    }

    /// Models offered in the picker (empty id = the CLI's own default).
    private static func models(for p: AIAccount.Provider) -> [[String: String]] {
        p == .claude
            ? [["id": "", "name": ""], ["id": "opus", "name": "Opus"],
               ["id": "sonnet", "name": "Sonnet"], ["id": "haiku", "name": "Haiku"]]
            : [["id": "", "name": ""]] + codexModels.map { ["id": $0, "name": $0] }
    }

    /// A JSON string as a JS string literal.
    private static func js(_ s: String) -> String {
        guard let d = try? JSONSerialization.data(withJSONObject: [s]),
              let arr = String(data: d, encoding: .utf8) else { return "\"\"" }
        return String(arr.dropFirst().dropLast())       // ["…"] → "…"
    }
}

/// WKWebView shows no JS dialogs by itself — `confirm()` silently returns false
/// and `prompt()` null — so the chat's "add / remove account" would do nothing.
extension ChatController: WKUIDelegate {
    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let a = NSAlert()
        a.messageText = message
        a.addButton(withTitle: LZ("確定"))
        a.addButton(withTitle: LZ("取消"))
        completionHandler(a.runModal() == .alertFirstButtonReturn)
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String,
                 defaultText: String?, initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping (String?) -> Void) {
        let a = NSAlert()
        a.messageText = prompt
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = defaultText ?? ""
        a.accessoryView = field
        a.addButton(withTitle: LZ("確定"))
        a.addButton(withTitle: LZ("取消"))
        a.window.initialFirstResponder = field
        completionHandler(a.runModal() == .alertFirstButtonReturn ? field.stringValue : nil)
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let a = NSAlert(); a.messageText = message; a.runModal(); completionHandler()
    }
}

/// WKWebView that accepts dropped files — a Zotero paper, a PDF, a CSV — and
/// hands their paths to the controller as chat attachments. Zotero (like
/// Finder) can also drop file *promises*, which are received into a temp folder
/// first.
final class ChatDropWebView: WKWebView {
    var onFiles: (([URL]) -> Void)?
    private static let promiseQueue = OperationQueue()

    private func fileURLs(_ pb: NSPasteboard) -> [URL] {
        (pb.readObjects(forClasses: [NSURL.self],
                        options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }
    private func accepts(_ pb: NSPasteboard) -> Bool {
        !fileURLs(pb).isEmpty || pb.canReadObject(forClasses: [NSFilePromiseReceiver.self], options: nil)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        accepts(sender.draggingPasteboard) ? .copy : super.draggingEntered(sender)
    }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        accepts(sender.draggingPasteboard) ? .copy : super.draggingUpdated(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let pb = sender.draggingPasteboard
        let urls = fileURLs(pb)
        if !urls.isEmpty { onFiles?(urls); return true }
        if let receivers = pb.readObjects(forClasses: [NSFilePromiseReceiver.self]) as? [NSFilePromiseReceiver],
           !receivers.isEmpty {
            let dest = FileManager.default.temporaryDirectory
                .appendingPathComponent("np-chat-drop-\(UUID().uuidString)", isDirectory: true)
            try? FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
            for r in receivers {
                r.receivePromisedFiles(atDestination: dest, options: [:],
                                       operationQueue: Self.promiseQueue) { [weak self] url, err in
                    guard err == nil else { return }
                    DispatchQueue.main.async { self?.onFiles?([url]) }
                }
            }
            return true
        }
        return super.performDragOperation(sender)
    }
}

/// Hosts `chat.html` from the app bundle.
struct ChatWebView: NSViewRepresentable {
    @ObservedObject var ctrl: ChatController

    func makeNSView(context: Context) -> WKWebView {
        if let wv = ctrl.webView { wv.removeFromSuperview(); return wv }   // keep the conversation
        let config = WKWebViewConfiguration()
        config.userContentController.add(WeakHandler(ctrl), name: "nebulaChat")
        config.setURLSchemeHandler(ImageSchemeHandler(), forURLScheme: "npimg")
        let wv = ChatDropWebView(frame: .zero, configuration: config)
        wv.setValue(false, forKey: "drawsBackground")
        wv.uiDelegate = ctrl
        wv.onFiles = { [weak ctrl] urls in ctrl?.addAttachments(urls) }
        ctrl.webView = wv
        if let url = Bundle.main.url(forResource: "chat", withExtension: "html") {
            wv.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }
        return wv
    }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

/// WKUserContentController retains its handlers; break the cycle.
private final class WeakHandler: NSObject, WKScriptMessageHandler {
    weak var target: (WKScriptMessageHandler & AnyObject)?
    init(_ t: WKScriptMessageHandler & AnyObject) { target = t }
    func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(ucc, didReceive: message)
    }
}

/// Side pane: the chat UI, with a switch to the raw terminal session.
struct ChatPane: View {
    let vault: URL?
    let onClose: () -> Void
    @StateObject private var ctrl = ChatController.shared
    @AppStorage("chatPaneTerminal") private var terminal = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Picker("", selection: $terminal) {
                    Text(LZ("對話")).tag(false)
                    Text(LZ("終端")).tag(true)
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 120)
                Spacer()
                Button(action: onClose) { Image(systemName: "xmark") }
                    .buttonStyle(.borderless).help(LZ("關閉側欄（對話保留）"))
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            Divider()
            // Both panes stay in the hierarchy and are only hidden — swapping
            // them with `if/else` would tear the chat's web view (and the live
            // terminal) down and lose what's on screen.
            ZStack {
                ChatWebView(ctrl: ctrl)
                    .opacity(terminal ? 0 : 1)
                    .allowsHitTesting(!terminal)
                ClaudeTermPane(vault: vault, onClose: onClose)
                    .opacity(terminal ? 1 : 0)
                    .allowsHitTesting(terminal)
            }
        }
    }
}
