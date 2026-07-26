import PDFKit
import SwiftUI

struct PDFPreview: NSViewRepresentable {
    let url: URL

    final class Coordinator {
        var loadedURL: URL?
        var loadedDate: Date?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.backgroundColor = .windowBackgroundColor
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        let modified =
            (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate
        guard url != context.coordinator.loadedURL
            || modified != context.coordinator.loadedDate
        else { return }
        context.coordinator.loadedURL = url
        context.coordinator.loadedDate = modified
        view.document = PDFDocument(url: url)
    }
}
