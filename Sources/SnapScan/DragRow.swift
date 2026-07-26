import AppKit
import SwiftUI

/// Wraps a sidebar row so it can act as an AppKit drag source with real
/// move/copy semantics: dragging to Finder defaults to a move (the file is
/// removed here once Finder has it), holding Option makes it a copy. A plain
/// click falls through to `onSelect`.
struct DragRow<Content: View>: NSViewRepresentable {
    let url: URL
    /// When false (e.g. while renaming inline), clicks pass through to the
    /// SwiftUI content instead of being claimed for selection/drag.
    var interceptsClicks: Bool = true
    let onSelect: () -> Void
    let onMoved: (URL) -> Void
    @ViewBuilder let content: () -> Content

    func makeNSView(context: Context) -> DragRowView {
        let view = DragRowView()
        view.hosted = NSHostingView(rootView: AnyView(content()))
        view.configure(
            url: url, interceptsClicks: interceptsClicks,
            onSelect: onSelect, onMoved: onMoved)
        return view
    }

    func updateNSView(_ view: DragRowView, context: Context) {
        view.hosted?.rootView = AnyView(content())
        view.configure(
            url: url, interceptsClicks: interceptsClicks,
            onSelect: onSelect, onMoved: onMoved)
    }
}

final class DragRowView: NSView, NSDraggingSource {
    var hosted: NSHostingView<AnyView>?
    private var url: URL = URL(fileURLWithPath: "/")
    private var interceptsClicks = true
    private var onSelect: () -> Void = {}
    private var onMoved: (URL) -> Void = { _ in }
    private var mouseDownLocation: NSPoint?

    func configure(
        url: URL, interceptsClicks: Bool,
        onSelect: @escaping () -> Void, onMoved: @escaping (URL) -> Void
    ) {
        self.url = url
        self.interceptsClicks = interceptsClicks
        self.onSelect = onSelect
        self.onMoved = onMoved
        if let hosted, hosted.superview == nil {
            hosted.translatesAutoresizingMaskIntoConstraints = false
            addSubview(hosted)
            NSLayoutConstraint.activate([
                hosted.leadingAnchor.constraint(equalTo: leadingAnchor),
                hosted.trailingAnchor.constraint(equalTo: trailingAnchor),
                hosted.topAnchor.constraint(equalTo: topAnchor),
                hosted.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Claim mouse events so clicks and drags reach this view rather than
        // the hosted SwiftUI content — except while inline-renaming.
        guard interceptsClicks else { return super.hitTest(point) }
        return frame.contains(point) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownLocation = event.locationInWindow
    }

    override func rightMouseDown(with event: NSEvent) {
        let menu = NSMenu()
        let reveal = NSMenuItem(
            title: "Reveal in Finder", action: #selector(revealInFinder), keyEquivalent: "")
        reveal.target = self
        menu.addItem(reveal)
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc private func revealInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    override func mouseUp(with event: NSEvent) {
        if mouseDownLocation != nil {
            onSelect()
        }
        mouseDownLocation = nil
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = mouseDownLocation else { return }
        let distance = hypot(
            event.locationInWindow.x - start.x,
            event.locationInWindow.y - start.y)
        guard distance > 5 else { return }
        mouseDownLocation = nil

        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        item.setDraggingFrame(bounds, contents: snapshot())
        beginDraggingSession(with: [item], event: event, source: self)
    }

    private func snapshot() -> NSImage? {
        guard let rep = bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
        cacheDisplay(in: bounds, to: rep)
        let image = NSImage(size: bounds.size)
        image.addRepresentation(rep)
        return image
    }

    // MARK: NSDraggingSource

    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        context == .outsideApplication ? [.move, .copy] : []
    }

    func draggingSession(
        _ session: NSDraggingSession, endedAt screenPoint: NSPoint,
        operation: NSDragOperation
    ) {
        guard operation == .move else { return }
        // The destination took the file as a move. If the original still exists
        // (the destination copied rather than relocated it), retire it to the
        // Trash so the "move" doesn't silently become a duplicate.
        if FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
        }
        onMoved(url)
    }
}
