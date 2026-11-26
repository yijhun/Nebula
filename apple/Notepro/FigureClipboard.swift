import Foundation
import PDFKit
import AppKit

/// Figures cropped out of a paper, handed to other apps — mainly Keynote.
///
/// A crop is a one-page PDF whose page is the selected region, so it stays
/// vector (or keeps the paper's own bitmap at full resolution). On the
/// pasteboard it goes as PDF data plus a file URL: ⌘V in Keynote gives the
/// figure as a resizable image, and Finder-paste gives a `.pdf` file. The
/// same file backs drag-and-drop.
enum FigureClipboard {

    /// One-page PDF of `rect` (PDF page space) on `page`. The source page is
    /// copied, so the caller's on-screen page keeps its full bounds.
    static func croppedPDF(page: PDFPage, rect: CGRect) -> Data? {
        guard rect.width > 1, rect.height > 1,
              let clip = page.copy() as? PDFPage else { return nil }
        clip.setBounds(rect, for: .cropBox)
        clip.setBounds(rect, for: .mediaBox)
        let doc = PDFDocument()
        doc.insert(clip, at: 0)
        return doc.dataRepresentation()
    }

    /// Write `data` to a temp `.pdf` named after `name` and return its URL.
    /// Reuses one folder, so temp files don't pile up across launches.
    static func tempFile(_ data: Data, name: String) -> URL? {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("np-figure-pdf", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let safe = name.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        let url = dir.appendingPathComponent(safe.hasSuffix(".pdf") ? safe : "\(safe).pdf")
        do { try data.write(to: url) } catch { return nil }
        return url
    }

    /// Put the PDF on the pasteboard (PDF data + file URL).
    /// Returns false if the temp file couldn't be written.
    @discardableResult
    static func copy(_ data: Data, name: String, to pb: NSPasteboard = .general) -> Bool {
        guard let file = tempFile(data, name: name) else { return false }
        let item = NSPasteboardItem()
        item.setData(data, forType: .pdf)
        item.setString(file.absoluteString, forType: .fileURL)
        pb.clearContents()
        return pb.writeObjects([item])
    }
}
