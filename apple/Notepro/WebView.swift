import SwiftUI
import WebKit

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

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground") // avoid white flash
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
