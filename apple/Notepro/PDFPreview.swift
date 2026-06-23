import SwiftUI
import PDFKit

/// A live PDF preview pane (PDFKit) for LaTeX mode. Reloads when `version`
/// changes (the in-place preview reuses a stable file path), preserving the
/// current page so recompiles aren't jarring.
struct PDFPreview: NSViewRepresentable {
    let url: URL?
    let version: Int

    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator { var loadedVersion = -1 }

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.backgroundColor = .windowBackgroundColor
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        guard let url else {
            view.document = nil
            context.coordinator.loadedVersion = -1
            return
        }
        if context.coordinator.loadedVersion == version { return }
        guard let doc = PDFDocument(url: url) else { return }
        let pageIndex = view.currentPage.flatMap { view.document?.index(for: $0) } ?? 0
        view.document = doc
        context.coordinator.loadedVersion = version
        if pageIndex > 0, pageIndex < doc.pageCount, let page = doc.page(at: pageIndex) {
            view.go(to: page)
        }
    }
}
