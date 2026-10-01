import Foundation
import PDFKit
import AppKit
import CryptoKit

/// Renders hand-written ```tikz blocks for the Markdown preview by compiling
/// them with tectonic (so every package and library the snippet uses works —
/// unlike a JS TeX subset) and handing back a PNG data URL.
///
/// Results are cached on disk by content hash: editing elsewhere in the note
/// re-renders the preview constantly, and a diagram must not recompile each
/// time. One compile runs at a time; identical requests share it.
final class TikzRenderer {
    static let shared = TikzRenderer()

    private let queue = DispatchQueue(label: "nebula.tikz", qos: .userInitiated)
    private var memo: [String: String] = [:]                  // hash → data URL
    private var waiting: [String: [(String?) -> Void]] = [:]   // hash → callbacks
    private let lock = NSLock()

    /// Application Support, not the temp dir: macOS prunes temporary files, and
    /// a diagram that has been in a note for weeks should not recompile just
    /// because the machine rebooted.
    private var cacheDir: URL {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Nebula/tikz", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    /// Compile `src` (a bare tikzpicture, or any body) and return a PNG data
    /// URL, or nil when it doesn't compile. Completion is on the main queue.
    func render(_ src: String, vaultRoot: URL?, completion: @escaping (String?) -> Void) {
        let body = src.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { completion(nil); return }
        let hash = Self.sha(body)

        lock.lock()
        if let hit = memo[hash] {
            lock.unlock()
            DispatchQueue.main.async { completion(hit.isEmpty ? nil : hit) }
            return
        }
        if waiting[hash] != nil {                  // a compile is already running
            waiting[hash]?.append(completion)
            lock.unlock()
            return
        }
        waiting[hash] = [completion]
        lock.unlock()

        queue.async { [weak self] in
            guard let self else { return }
            let png = self.cacheDir.appendingPathComponent("\(hash).png")
            var url: String?
            if let data = try? Data(contentsOf: png) {
                url = "data:image/png;base64," + data.base64EncodedString()
            } else if let data = self.compile(body, vaultRoot: vaultRoot) {
                try? data.write(to: png)
                url = "data:image/png;base64," + data.base64EncodedString()
            }
            self.lock.lock()
            self.memo[hash] = url ?? ""
            let callbacks = self.waiting.removeValue(forKey: hash) ?? []
            self.lock.unlock()
            DispatchQueue.main.async { callbacks.forEach { $0(url) } }
        }
    }

    /// tectonic → one-page standalone PDF → 2x PNG.
    private func compile(_ body: String, vaultRoot: URL?) -> Data? {
        // `standalone` crops to the drawing; ctex only when the snippet has CJK
        // (loading it always would slow every compile down).
        let hasCJK = body.unicodeScalars.contains {
            (0x4E00...0x9FFF).contains($0.value) || (0x3040...0x30FF).contains($0.value)
            || (0xAC00...0xD7AF).contains($0.value)
        }
        let wrapped = body.contains("\\begin{tikzpicture}")
            ? body : "\\begin{tikzpicture}\n\(body)\n\\end{tikzpicture}"
        let doc = """
        \\documentclass[margin=3pt]{standalone}
        \\usepackage{tikz}
        \\usepackage{pgfplots}
        \\pgfplotsset{compat=1.17}
        \\usepackage{amsmath,amssymb}
        \(hasCJK ? "\\usepackage{ctex}" : "")
        \\begin{document}
        \(wrapped)
        \\end{document}
        """
        // Compile inside the vault when there is one, so \input / images that
        // sit next to the note resolve.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("nebula-tikz-build", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        _ = vaultRoot

        let sem = DispatchSemaphore(value: 0)
        var pdfURL: URL?
        PDFExporter.compilePreview(content: doc, in: dir) { result in
            if case .success(let u) = result { pdfURL = u }
            sem.signal()
        }
        // compilePreview hops to main to call back; this runs off-main so the
        // wait is safe. Bounded so a pathological snippet can't wedge the queue.
        _ = sem.wait(timeout: .now() + 60)
        guard let pdfURL, let pdf = PDFDocument(url: pdfURL), let page = pdf.page(at: 0) else { return nil }

        let bounds = page.bounds(for: .cropBox)
        guard bounds.width > 1, bounds.height > 1 else { return nil }
        let img = page.thumbnail(of: CGSize(width: bounds.width * 2, height: bounds.height * 2),
                                 for: .cropBox)
        guard let tiff = img.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    private static func sha(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
