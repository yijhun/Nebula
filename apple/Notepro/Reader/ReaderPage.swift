import Foundation
import PDFKit
import AppKit

/// A PDF page that can draw itself dark while keeping figures in their real
/// colours (PAPER-LIBRARY.md §6.1, shown in the spike): after the normal
/// drawing, everything outside the figure regions is inverted and lifted to
/// a soft dark grey. Nothing in the PDF changes.
final class ReaderPage: PDFPage {

    /// On for every reader page; toggled from the reader toolbar.
    static var dark = UserDefaults.standard.bool(forKey: "readerDark")

    /// Figure regions (PDF points, bottom-left origin) per document and page,
    /// kept out of the inversion.
    private static var figureRegions: [ObjectIdentifier: [Int: [CGRect]]] = [:]

    static func setFigures(_ regions: [Int: [CGRect]], for doc: PDFDocument) {
        figureRegions[ObjectIdentifier(doc)] = regions
    }

    override func draw(with box: PDFDisplayBox, to context: CGContext) {
        super.draw(with: box, to: context)
        guard Self.dark, let doc = document else { return }
        let bounds = self.bounds(for: box)
        let figs = Self.figureRegions[ObjectIdentifier(doc)]?[doc.index(for: self)] ?? []

        context.saveGState()
        // super.draw leaves the context in page space with the box's origin;
        // clip to the page minus the figures (even-odd), then invert.
        let path = CGMutablePath()
        path.addRect(bounds)
        for r in figs { path.addRect(r.intersection(bounds)) }
        context.addPath(path)
        context.clip(using: .evenOdd)
        context.setBlendMode(.difference)
        context.setFillColor(NSColor.white.cgColor)
        context.fill(bounds)
        // Black paper → dark grey, so it is easier on the eyes than pure black.
        context.setBlendMode(.lighten)
        context.setFillColor(CGColor(gray: 0.12, alpha: 1))
        context.fill(bounds)
        context.restoreGState()
    }
}
