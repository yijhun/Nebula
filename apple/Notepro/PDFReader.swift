import SwiftUI
import PDFKit
import AppKit

/// Controls a live PDFView: highlight selections, save annotations back into the
/// PDF, and turn highlights into a linked literature note. One per reader window.
final class PDFController: ObservableObject {
    let url: URL
    let document: PDFDocument?
    weak var pdfView: PDFView?

    @Published var citekey: String = ""
    @Published var status: String = ""
    @Published var zoteroQuery: String = ""
    @Published var zoteroResults: [ZoteroItem] = []

    init(url: URL) {
        self.url = url
        self.document = PDFDocument(url: url)
    }

    /// Highlight the current text selection (yellow), line by line.
    func highlightSelection() {
        guard let pv = pdfView, let sel = pv.currentSelection else { status = "先選取文字再標記"; return }
        var n = 0
        for line in sel.selectionsByLine() {
            guard let page = line.pages.first else { continue }
            let ann = PDFAnnotation(bounds: line.bounds(for: page), forType: .highlight, withProperties: nil)
            ann.color = NSColor.systemYellow.withAlphaComponent(0.45)
            page.addAnnotation(ann)
            n += 1
        }
        pv.clearSelection()
        status = n > 0 ? "已標記" : "沒有可標記的選取"
    }

    /// Write annotations back into the PDF file on disk.
    func saveAnnotations() {
        guard let doc = document else { return }
        status = doc.write(to: url) ? "標註已存回 PDF" : "存檔失敗"
    }

    /// Collect every highlight's text, in reading order (page, then top-down).
    private func collectHighlights() -> [(page: Int, text: String)] {
        guard let doc = document else { return [] }
        var out: [(Int, String)] = []
        for p in 0 ..< doc.pageCount {
            guard let page = doc.page(at: p) else { continue }
            let highs = page.annotations.filter { $0.type == "Highlight" || $0.type == "/Highlight" }
            let sorted = highs.sorted { $0.bounds.maxY > $1.bounds.maxY } // top-down
            for ann in sorted {
                let text = page.selection(for: ann.bounds)?.string?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if !text.isEmpty { out.append((p + 1, text)) }
            }
        }
        return out
    }

    /// Search Zotero for a paper to attach (so the note links to a citekey).
    func searchZotero() {
        let q = zoteroQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        ZoteroService.search(q) { [weak self] items in self?.zoteroResults = items }
    }

    /// Build a literature note from the highlights, linked to the PDF + citekey.
    @discardableResult
    func makeNote(in vault: VaultModel) -> URL? {
        let highs = collectHighlights()
        guard !highs.isEmpty else { status = "還沒有任何螢光標記"; return nil }
        guard let root = vault.rootURL else { status = "請先開啟資料夾"; return nil }

        let base = url.deletingPathExtension().lastPathComponent
        let key = citekey.trimmingCharacters(in: .whitespacesAndNewlines)
        var fm = "---\ntitle: \(base)\ntype: literature-note\n"
        if !key.isEmpty { fm += "cite: \(key)\n" }
        fm += "---\n\n"
        var body = "# \(base)\n\n[[\(url.lastPathComponent)]]"
        if !key.isEmpty { body += " · [@\(key)]" }
        body += "\n\n## 重點摘錄\n\n"
        for h in highs {
            body += "> [p.\(h.page)] \(h.text)\n\n"
        }

        let fmgr = FileManager.default
        var noteURL = root.appendingPathComponent("\(base).md")
        var i = 2
        while fmgr.fileExists(atPath: noteURL.path) {
            noteURL = root.appendingPathComponent("\(base) \(i).md"); i += 1
        }
        do {
            try (fm + body).write(to: noteURL, atomically: true, encoding: .utf8)
            saveAnnotations() // persist the highlights into the PDF too
            vault.refresh()
            status = "已建立文獻筆記：\(noteURL.lastPathComponent)（\(highs.count) 條摘錄）"
            return noteURL
        } catch {
            status = "建立筆記失敗：\(error.localizedDescription)"
            return nil
        }
    }
}

/// NSViewRepresentable wrapper around PDFView (selection + annotation enabled).
struct PDFKitView: NSViewRepresentable {
    let controller: PDFController
    func makeNSView(context: Context) -> PDFView {
        let v = PDFView()
        v.autoScales = true
        v.displayMode = .singlePageContinuous
        v.displaysPageBreaks = true
        v.document = controller.document
        controller.pdfView = v
        return v
    }
    func updateNSView(_ nsView: PDFView, context: Context) {}
}

/// A paper-reading window: read a PDF, highlight, and turn highlights into a
/// literature note linked to a Zotero citekey. Closes the research loop
/// (read → highlight → note → cite).
struct PDFReaderView: View {
    @EnvironmentObject var vault: VaultModel
    @StateObject private var ctrl: PDFController

    init(url: URL) { _ctrl = StateObject(wrappedValue: PDFController(url: url)) }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            PDFKitView(controller: ctrl)
                .frame(minWidth: 480, minHeight: 400)
        }
        .navigationTitle(ctrl.url.lastPathComponent)
    }

    private var toolbar: some View {
        VStack(spacing: 6) {
            HStack(spacing: 10) {
                Button { ctrl.highlightSelection() } label: { Label("螢光標記", systemImage: "highlighter") }
                Button { ctrl.saveAnnotations() } label: { Label("存標註", systemImage: "tray.and.arrow.down") }
                Divider().frame(height: 16)
                Button { ctrl.makeNote(in: vault) } label: { Label("建立文獻筆記", systemImage: "note.text.badge.plus") }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                Spacer()
                Text(ctrl.status).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            HStack(spacing: 6) {
                Image(systemName: "books.vertical").foregroundStyle(.secondary)
                TextField("連結 Zotero 文獻（搜尋作者/標題）…", text: $ctrl.zoteroQuery)
                    .textFieldStyle(.roundedBorder).frame(maxWidth: 260)
                    .onSubmit { ctrl.searchZotero() }
                if !ctrl.citekey.isEmpty {
                    Text("已連結 [@\(ctrl.citekey)]").font(.caption).foregroundStyle(.blue)
                }
                if !ctrl.zoteroResults.isEmpty {
                    Menu("選擇 (\(ctrl.zoteroResults.count))") {
                        ForEach(ctrl.zoteroResults) { item in
                            Button("\(item.citekey) — \(item.title)") {
                                ctrl.citekey = item.citekey; ctrl.zoteroResults = []
                            }
                        }
                    }
                    .frame(maxWidth: 120)
                }
                Spacer()
            }
        }
        .padding(8)
    }
}
