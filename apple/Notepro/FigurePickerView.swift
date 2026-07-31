import SwiftUI
import PDFKit
import AppKit

/// Pick a figure out of a cited paper and drop it into the note.
///
/// Figures come from `FigureExtractor` (the zotero-figure plugin's cache when
/// present, else pdffigures2). Choosing one copies its PNG into the vault,
/// also crops a **vector PDF** of the same region out of the source paper (for
/// lossless LaTeX export), and inserts the embed + caption at the cursor.
struct FigurePickerView: View {
    let citekey: String
    let paperTitle: String
    let onInserted: (String) -> Void      // markdown to place at the cursor
    let onClose: () -> Void

    @EnvironmentObject var vault: VaultModel

    @State private var figures: [PaperFigure] = []
    @State private var pdfPath: URL?
    @State private var loading = true
    @State private var source = ""
    @State private var status = ""
    @State private var showFormulas = false
    /// Papers' own captions are often a whole paragraph — too much for a note,
    /// so they're opt-in. The short attribution line is always kept, otherwise
    /// a figure in your notes has no traceable source.
    @AppStorage("figureIncludeCaption") private var includeCaption = false

    private var shown: [PaperFigure] {
        showFormulas ? figures : figures.filter(\.isFigureOrTable)
    }
    private var formulaCount: Int { figures.count - figures.filter(\.isFigureOrTable).count }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 760, height: 560)
        .onAppear(perform: load)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "photo.on.rectangle.angled").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(paperTitle.isEmpty ? citekey : paperTitle)
                    .font(.subheadline.weight(.semibold)).lineLimit(1)
                Text("[@\(citekey)]").font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            Toggle(LZ("含圖說"), isOn: $includeCaption)
                .toggleStyle(.switch).controlSize(.small)
                .help(LZ("插入論文原本的圖說全文（預設只放一行出處）"))
            if formulaCount > 0 {
                Toggle(LZ("含公式"), isOn: $showFormulas)
                    .toggleStyle(.switch).controlSize(.small)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    @ViewBuilder private var content: some View {
        if loading {
            VStack(spacing: 10) {
                Spacer()
                ProgressView()
                Text(LZ("分析論文中…（第一次約 1–2 秒）")).font(.caption).foregroundStyle(.secondary)
                Spacer()
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if shown.isEmpty {
            VStack(spacing: 8) {
                Spacer()
                Image(systemName: "photo").font(.largeTitle).foregroundStyle(.tertiary)
                Text(LZ("這篇論文找不到圖")).foregroundStyle(.secondary)
                Text(LZ("可以改用「讀 PDF」手動框選擷取。"))
                    .font(.caption).foregroundStyle(.tertiary)
                Spacer()
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: 14)], spacing: 14) {
                    ForEach(shown) { fig in card(fig) }
                }
                .padding(14)
            }
        }
    }

    private func card(_ fig: PaperFigure) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            ZStack {
                RoundedRectangle(cornerRadius: 6).fill(Color.white)
                if let img = NSImage(contentsOf: fig.image) {
                    Image(nsImage: img).resizable().scaledToFit().padding(4)
                }
            }
            .frame(height: 140)
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.25)))
            HStack(spacing: 5) {
                Text(fig.tag).font(.caption.weight(.semibold))
                Text("p.\(fig.pageIndex + 1)").font(.caption2).foregroundStyle(.secondary)
            }
            Text(fig.caption).font(.caption2).foregroundStyle(.secondary)
                .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
        }
        .contentShape(Rectangle())
        .onTapGesture { insert(fig) }
        .help(fig.caption)
    }

    private var footer: some View {
        HStack {
            Text(status.isEmpty
                 ? "\(shown.count) \(LZ("張")) \(source.isEmpty ? "" : "· \(source)")"
                 : status)
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Spacer()
            Button(LZ("關閉"), action: onClose).keyboardShortcut(.escape, modifiers: [])
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
    }

    // MARK: - load / insert

    private func load() {
        loading = true
        ZoteroService.attachments(citekey) { atts in
            guard let pdf = atts.first(where: \.isPDF) else {
                loading = false
                status = LZ("這筆文獻在 Zotero 沒有 PDF 附件")
                return
            }
            pdfPath = URL(fileURLWithPath: pdf.path)
            FigureExtractor.figures(pdf: URL(fileURLWithPath: pdf.path),
                                    attachmentKey: pdf.itemKey) { figs, src in
                figures = figs
                source = src == "zotero-figure" ? "zotero-figure 快取" : (src == "pdffigures2" ? "pdffigures2" : "")
                loading = false
            }
        }
    }

    /// Copy the chosen figure into the vault (PNG for preview + cropped vector
    /// PDF for LaTeX) and hand the markdown back for insertion.
    private func insert(_ fig: PaperFigure) {
        guard let root = vault.rootURL else { status = LZ("請先開啟資料夾"); return }
        let d = UserDefaults.standard
        let folder = (d.string(forKey: "attachmentFolder") ?? "Assets")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let dir = folder.isEmpty ? root : root.appendingPathComponent(folder, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let fm = FileManager.default
        let slug = fig.tag.replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "/", with: "-")
        let stem = "fig-\(citekey)-\(slug)"
        // Inserting the same figure twice should point at the file already in
        // the vault, not pile up -2, -3, -4… copies of identical bytes. Only a
        // genuinely different image under the same name gets a new number.
        let incoming = try? Data(contentsOf: fig.image)
        var base = stem
        var png = dir.appendingPathComponent("\(base).png")
        var n = 2
        var needsCopy = true
        while fm.fileExists(atPath: png.path) {
            if let incoming, let existing = try? Data(contentsOf: png), existing == incoming {
                needsCopy = false; break
            }
            base = "\(stem)-\(n)"; png = dir.appendingPathComponent("\(base).png"); n += 1
        }
        if needsCopy {
            do { try fm.copyItem(at: fig.image, to: png) }
            catch { status = "\(LZ("複製失敗"))：\(error.localizedDescription)"; return }
        }

        // Vector companion, cropped from the source paper at the same region.
        let vecURL = dir.appendingPathComponent("\(base).pdf")
        if !fm.fileExists(atPath: vecURL.path),
           let rect = fig.rect, let src = pdfPath, let doc = PDFDocument(url: src),
           let page = doc.page(at: fig.pageIndex), let clip = page.copy() as? PDFPage {
            clip.setBounds(rect, for: .cropBox)
            clip.setBounds(rect, for: .mediaBox)
            let vec = PDFDocument(); vec.insert(clip, at: 0)
            vec.write(to: vecURL)
        }

        // Always a one-line source; the paper's full caption only when asked for.
        var cap = "\(fig.tag) · [@\(citekey)] p.\(fig.pageIndex + 1)"
        if includeCaption, !fig.caption.isEmpty { cap = "\(fig.caption) — \(cap)" }
        onInserted("\n![[\(png.lastPathComponent)]]\n*\(cap)*\n")
        vault.refresh()
        status = "\(LZ("已插入")) \(png.lastPathComponent)"
    }
}
