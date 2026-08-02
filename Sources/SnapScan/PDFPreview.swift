import PDFKit
import SwiftUI

/// PDFView that keeps the plain arrow cursor. PDFKit's private document view
/// switches to a pointing hand over page content; it manages cursors in a
/// subview we can't override, so the hand is flattened back to an arrow on
/// mouse movement instead.
final class ArrowCursorPDFView: PDFView {
    private var arrowTracking: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let arrowTracking { removeTrackingArea(arrowTracking) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner: self)
        addTrackingArea(area)
        arrowTracking = area
    }

    override func cursorUpdate(with event: NSEvent) {
        NSCursor.arrow.set()
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        if NSCursor.current == NSCursor.pointingHand || NSCursor.current == NSCursor.openHand {
            NSCursor.arrow.set()
        }
    }
}

struct PDFPreview: NSViewRepresentable {
    let url: URL
    /// Called when the PDF can't be opened — the file moved out of reach,
    /// was replaced, or is unreadable. The caller drops it from the list
    /// rather than leaving an empty pane on screen.
    var onUnreadable: () -> Void = {}

    final class Coordinator {
        var loadedURL: URL?
        var loadedDate: Date?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> PDFView {
        let view = ArrowCursorPDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.backgroundColor = .windowBackgroundColor
        Self.adoptSafeAreaInsets(in: view)
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

        // Opening a scan can mean parsing a hundred megabytes; doing it here
        // would freeze the window. Load off the main thread and hand the
        // document back when it's ready.
        let target = url
        // Everything below is touched only on the main queue; the hops are
        // GCD's, so the compiler can't see that on its own.
        nonisolated(unsafe) let sink = view
        nonisolated(unsafe) let coordinator = context.coordinator
        nonisolated(unsafe) let report = onUnreadable
        DispatchQueue.global(qos: .userInitiated).async {
            let document = PDFDocument(url: target)
            DispatchQueue.main.async {
                // The selection may have moved on while this loaded.
                guard coordinator.loadedURL == target else { return }
                sink.document = document
                if document == nil { report() }
                Self.adoptSafeAreaInsets(in: sink)
            }
        }
    }

    /// Lets the PDF scroll under the glass toolbar: the view extends to the
    /// window top (ignoresSafeArea below) and PDFKit's internal scroll view
    /// re-insets its content from the window safe area.
    private static func adoptSafeAreaInsets(in view: PDFView) {
        for scrollView in view.subviews.compactMap({ $0 as? NSScrollView }) {
            scrollView.automaticallyAdjustsContentInsets = true
        }
    }
}
