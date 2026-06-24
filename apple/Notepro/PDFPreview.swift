import SwiftUI
import PDFKit

/// Live PDF preview pane (PDFKit). Reloads when `version` changes (the in-place
/// preview reuses a stable file path), preserving the current page so recompiles
/// aren't jarring.
/// SyncTeX integration:
///   • forward — `syncTarget` (set by EditorModel when the editor's cursor moves
///     and `synctex view` returns a position) → scroll to that page + paint a
///     short-lived yellow highlight on the matched box.
///   • reverse — double-click anywhere → run `synctex edit` for the clicked
///     point → `onReverse` jumps the editor to the resolved line.
struct PDFPreview: NSViewRepresentable {
    let url: URL?
    let version: Int
    let syncTarget: EditorModel.SyncTarget?
    var onReverse: ((Int, CGFloat, CGFloat) -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator(onReverse: onReverse) }
    final class Coordinator: NSObject {
        var loadedVersion = -1
        var appliedTargetVersion = -1
        weak var pdfView: PDFView?
        var onReverse: ((Int, CGFloat, CGFloat) -> Void)?
        init(onReverse: ((Int, CGFloat, CGFloat) -> Void)?) {
            self.onReverse = onReverse
        }
        @objc func handleDoubleClick(_ g: NSClickGestureRecognizer) {
            guard let view = pdfView, let doc = view.document else { return }
            let viewPoint = g.location(in: view)
            guard let page = view.page(for: viewPoint, nearest: true) else { return }
            // PDFKit pages use a bottom-left origin; SyncTeX expects top-left.
            let pagePoint = view.convert(viewPoint, to: page)
            let bounds = page.bounds(for: .mediaBox)
            let x = pagePoint.x
            let y = bounds.height - pagePoint.y
            let pageIndex = doc.index(for: page) + 1
            onReverse?(pageIndex, x, y)
        }
    }

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.backgroundColor = .windowBackgroundColor
        let g = NSClickGestureRecognizer(target: context.coordinator,
                                         action: #selector(Coordinator.handleDoubleClick(_:)))
        g.numberOfClicksRequired = 2
        view.addGestureRecognizer(g)
        context.coordinator.pdfView = view
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        // Pick up potential closure changes (SwiftUI re-makes view structs).
        context.coordinator.onReverse = onReverse

        guard let url else {
            view.document = nil
            context.coordinator.loadedVersion = -1
            context.coordinator.appliedTargetVersion = -1
            return
        }
        if context.coordinator.loadedVersion != version {
            guard let doc = PDFDocument(url: url) else { return }
            let pageIndex = view.currentPage.flatMap { view.document?.index(for: $0) } ?? 0
            view.document = doc
            context.coordinator.loadedVersion = version
            if pageIndex > 0, pageIndex < doc.pageCount, let page = doc.page(at: pageIndex) {
                view.go(to: page)
            }
            // A reload invalidates any previous highlight — let the next
            // syncTarget below re-apply if appropriate.
            context.coordinator.appliedTargetVersion = -1
        }

        // SyncTeX forward: scroll + flash highlight on the matched box.
        if let t = syncTarget,
           context.coordinator.appliedTargetVersion != t.version,
           let doc = view.document,
           t.page >= 1, t.page <= doc.pageCount,
           let page = doc.page(at: t.page - 1) {
            context.coordinator.appliedTargetVersion = t.version
            let bounds = page.bounds(for: .mediaBox)
            // Flip from SyncTeX (top-left origin) to PDFKit (bottom-left).
            let r = CGRect(x: t.rect.minX,
                           y: bounds.height - t.rect.minY - t.rect.height,
                           width: t.rect.width, height: t.rect.height)
            if let dest = (try? PDFDestination(page: page, at: CGPoint(x: r.minX, y: r.maxY + 60))) ?? nil {
                view.go(to: dest)
            }
            // Yellow rectangle annotation, removed after ~1.5s. PDFKit doesn't
            // expose a non-destructive "highlight on top of page" API, so a
            // temporary annotation is the lightest path.
            let ann = PDFAnnotation(bounds: r, forType: .highlight, withProperties: nil)
            ann.color = NSColor.systemYellow.withAlphaComponent(0.55)
            page.addAnnotation(ann)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak page] in
                page?.removeAnnotation(ann)
            }
        }
    }
}
