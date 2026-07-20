import SwiftUI
import WebKit
import UniformTypeIdentifiers

/// WKWebView that also accepts image DATA drags (Keynote objects/slides,
/// images dragged from browsers…). Those drags carry PDF/TIFF/PNG bytes or a
/// file promise — no real file URL — so the DOM drop handler never sees them.
/// Plain file drops still flow through the DOM path untouched.
final class ImageDropWebView: WKWebView {
    /// Called with raw image bytes + a suggested filename extension.
    var onImageData: ((Data, String) -> Void)?

    private static let dataTypes: [NSPasteboard.PasteboardType] =
        [.pdf, .png, .tiff]
    private static let promiseQueue = OperationQueue()

    private func hasFileURLs(_ pb: NSPasteboard) -> Bool {
        (pb.readObjects(forClasses: [NSURL.self],
                        options: [.urlReadingFileURLsOnly: true]) as? [URL])?.isEmpty == false
    }
    private func wantsNativeHandling(_ pb: NSPasteboard) -> Bool {
        guard !hasFileURLs(pb) else { return false }   // DOM handles real files
        if Self.dataTypes.contains(where: { pb.data(forType: $0) != nil }) { return true }
        return pb.canReadObject(forClasses: [NSFilePromiseReceiver.self], options: nil)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        wantsNativeHandling(sender.draggingPasteboard) ? .copy : super.draggingEntered(sender)
    }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        wantsNativeHandling(sender.draggingPasteboard) ? .copy : super.draggingUpdated(sender)
    }

    /// ⌘V with an image on the clipboard (Keynote object/slide copy, screenshot,
    /// browser image copy…): route it through the same import path as drags.
    /// ⌘V only steps in when the clipboard is image-data-only (no text, no
    /// files), so normal text pasting is untouched. ⇧⌘V FORCES paste-as-image:
    /// any image flavor wins even when the copy also carries text (Keynote
    /// shapes with labels do). WKWebView doesn't expose `paste(_:)` for
    /// overriding, so interception happens at the key-equivalent level.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        // Match the PHYSICAL key (kVK_ANSI_V = 9) OR either character field:
        // with a CJK input source (e.g. Zhuyin) the V key reports "ㄇ" in
        // charactersIgnoringModifiers, so a pure character comparison never
        // fires for Chinese-input users; synthetic events may carry keyCode 0
        // with the character only in `characters`.
        let isV = event.keyCode == 9
            || event.charactersIgnoringModifiers?.lowercased() == "v"
            || event.characters?.lowercased() == "v"
        if isV {
            if mods == [.command, .shift] { if pasteImage(force: true) { return true } }
            else if mods == .command { if pasteImage(force: false) { return true } }
        }
        return super.performKeyEquivalent(with: event)
    }

    /// Menu-path entry ("編輯 ▸ 貼上為圖片"): always prefers image data.
    @discardableResult
    func pasteAsImage() -> Bool { pasteImage(force: true) }

    private func pasteImage(force: Bool) -> Bool {
        let pb = NSPasteboard.general
        logPasteboard(pb, force: force)
        if !force {
            guard pb.string(forType: .string) == nil, !hasFileURLs(pb) else { return false }
        }
        for type in Self.dataTypes {
            if let data = pb.data(forType: type) {
                deliver(data, ext: type == .pdf ? "pdf" : type == .png ? "png" : "tiff")
                return true
            }
        }
        // Force mode: fall back to whatever NSImage can decode from the board
        // (covers exotic single-flavor image types).
        if force, let img = NSImage(pasteboard: pb),
           let tiff = img.tiffRepresentation {
            deliver(tiff, ext: "tiff")
            return true
        }
        return false
    }

    /// Diagnostic breadcrumb: what flavors did the copy actually carry?
    private func logPasteboard(_ pb: NSPasteboard, force: Bool) {
        let types = (pb.types ?? []).map(\.rawValue).joined(separator: ", ")
        Self.debugLog("paste force=\(force) types=[\(types)]")
    }

    static func debugLog(_ msg: String) {
        let line = "[\(Date())] \(msg)\n"
        let u = URL(fileURLWithPath: "/tmp/notepro-paste.log")
        if let d = line.data(using: .utf8) {
            if let h = try? FileHandle(forWritingTo: u) { h.seekToEndOfFile(); h.write(d); try? h.close() }
            else { try? d.write(to: u) }
        }
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let pb = sender.draggingPasteboard
        guard wantsNativeHandling(pb) else { return super.performDragOperation(sender) }
        // Direct data flavors first (Keynote canvas objects give PDF + TIFF).
        for type in Self.dataTypes {
            if let data = pb.data(forType: type) {
                deliver(data, ext: type == .pdf ? "pdf" : type == .png ? "png" : "tiff")
                return true
            }
        }
        // File promises (e.g. slide thumbnails): receive into temp, then import.
        if let receivers = pb.readObjects(forClasses: [NSFilePromiseReceiver.self]) as? [NSFilePromiseReceiver],
           !receivers.isEmpty {
            let dest = FileManager.default.temporaryDirectory
                .appendingPathComponent("np-drop-\(UUID().uuidString)", isDirectory: true)
            try? FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
            for r in receivers {
                r.receivePromisedFiles(atDestination: dest, options: [:],
                                       operationQueue: Self.promiseQueue) { [weak self] url, err in
                    guard err == nil, let data = try? Data(contentsOf: url) else { return }
                    DispatchQueue.main.async {
                        self?.deliver(data, ext: url.pathExtension.lowercased())
                    }
                }
            }
            return true
        }
        return false
    }

    /// Normalize to PNG (preview + LaTeX friendly): PDF/TIFF are rasterized at
    /// 2x; PNG/JPEG pass through unchanged.
    private func deliver(_ data: Data, ext: String) {
        switch ext {
        case "png", "jpg", "jpeg", "gif", "webp":
            onImageData?(data, ext)
        default:
            if let png = Self.rasterizePNG(data) { onImageData?(png, "png") }
        }
    }

    static func rasterizePNG(_ data: Data, scale: CGFloat = 2) -> Data? {
        guard let image = NSImage(data: data), image.size.width > 0 else { return nil }
        let w = Int(image.size.width * scale), h = Int(image.size.height * scale)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                         isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = image.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(origin: .zero, size: image.size))
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }
}

/// Hosts the web core in a WKWebView and bridges it to `EditorModel`.
/// JS → Swift: `window.webkit.messageHandlers.notepro.postMessage(...)`.
/// Swift → JS: `evaluateJavaScript("window.notepro.<fn>(...)")` (see EditorModel).
struct WebView: NSViewRepresentable {
    @EnvironmentObject var model: EditorModel

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.userContentController.add(context.coordinator, name: "notepro")
        // Serve vault images to the (file://) preview via a custom scheme,
        // bypassing WKWebView's file:// subresource sandbox.
        config.setURLSchemeHandler(ImageSchemeHandler(), forURLScheme: "npimg")

        let webView = ImageDropWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground") // avoid white flash
        webView.onImageData = { [weak model] data, ext in
            model?.saveImageBytes(data, ext: ext)
        }
        model.attach(webView)

        if let url = Bundle.main.url(forResource: "index", withExtension: "html") {
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        let model: EditorModel
        init(model: EditorModel) { self.model = model }

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            guard
                let body = message.body as? [String: Any],
                let type = body["type"] as? String
            else { return }
            DispatchQueue.main.async {
                if type == "rpc" {
                    self.model.handleRPC(body)
                } else {
                    self.model.handleMessage(body)
                }
            }
        }
    }
}

/// Resolves `npimg://load?ref=…&base=…&vault=…` to a vault image and serves its
/// bytes. `ref` is the path as written (`![[x.png]]` or `![](fig/x.png)`),
/// resolved against the note's dir, then the vault root, then a vault-wide
/// filename search (Obsidian-style).
final class ImageSchemeHandler: NSObject, WKURLSchemeHandler {
    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url,
              let comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            task.didFailWithError(URLError(.badURL)); return
        }
        let q = comps.queryItems ?? []
        func val(_ n: String) -> String {
            let raw = q.first { $0.name == n }?.value ?? ""
            return raw.removingPercentEncoding ?? raw   // ref/base/vault arrive %-encoded
        }
        guard let file = Self.resolve(ref: val("ref"), base: val("base"), vault: val("vault")),
              let data = try? Data(contentsOf: file) else {
            let log = "[\(Date())] npimg miss ref=\(val("ref")) base=\(val("base")) vault=\(val("vault"))\n"
            if let d = log.data(using: .utf8) {
                let u = URL(fileURLWithPath: "/tmp/notepro-jserror.log")
                if let h = try? FileHandle(forWritingTo: u) { h.seekToEndOfFile(); h.write(d); try? h.close() }
                else { try? d.write(to: u) }
            }
            task.didFailWithError(URLError(.fileDoesNotExist)); return
        }
        let resp = URLResponse(url: url, mimeType: Self.mime(file.pathExtension),
                               expectedContentLength: data.count, textEncodingName: nil)
        task.didReceive(resp); task.didReceive(data); task.didFinish()
    }
    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}

    static func resolve(ref: String, base: String, vault: String) -> URL? {
        let fm = FileManager.default
        if ref.hasPrefix("/"), fm.fileExists(atPath: ref) { return URL(fileURLWithPath: ref) }
        if !base.isEmpty {
            let u = URL(fileURLWithPath: base).appendingPathComponent(ref)
            if fm.fileExists(atPath: u.path) { return u }
        }
        if !vault.isEmpty {
            let u = URL(fileURLWithPath: vault).appendingPathComponent(ref)
            if fm.fileExists(atPath: u.path) { return u }
            // Obsidian-style: search the vault for a file with this basename.
            let name = (ref as NSString).lastPathComponent
            if let en = fm.enumerator(at: URL(fileURLWithPath: vault),
                                      includingPropertiesForKeys: nil,
                                      options: [.skipsHiddenFiles]) {
                for case let f as URL in en where f.lastPathComponent == name { return f }
            }
        }
        return nil
    }

    static func mime(_ ext: String) -> String {
        switch ext.lowercased() {
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "svg": return "image/svg+xml"
        case "webp": return "image/webp"
        case "bmp": return "image/bmp"
        case "tif", "tiff": return "image/tiff"
        case "pdf": return "application/pdf"
        default: return "application/octet-stream"
        }
    }
}
