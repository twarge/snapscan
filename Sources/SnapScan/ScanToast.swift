import AppKit
import SwiftUI

/// Floating notification-style panel shown near the menu bar while a
/// hardware-button scan runs in menu-bar-only mode. Displays the most recent
/// page as it arrives; in combine mode it offers the Done button, otherwise
/// it fades out shortly after the scan completes.
@MainActor
final class ScanToastController {
    private var panel: NSPanel?
    private var hideTimer: Timer?

    func show(engine: ScannerEngine) {
        hideTimer?.invalidate()
        hideTimer = nil

        if panel == nil {
            let content = ScanToastView(
                onDone: { [weak self] in
                    engine.done()
                    self?.hide()
                },
                onClose: { [weak self] in self?.hide() }
            )
            .environment(engine)

            let hosting = NSHostingView(rootView: content)
            let newPanel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 340, height: 96),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered, defer: false)
            newPanel.isOpaque = false
            newPanel.backgroundColor = .clear
            newPanel.hasShadow = true
            newPanel.level = .statusBar
            newPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            newPanel.isReleasedWhenClosed = false
            newPanel.contentView = hosting
            panel = newPanel
        }

        guard let panel, let screen = NSScreen.main else { return }
        panel.setContentSize(panel.contentView?.fittingSize ?? panel.frame.size)
        let visible = screen.visibleFrame
        panel.setFrameTopLeftPoint(
            NSPoint(
                x: visible.maxX - panel.frame.width - 12,
                y: visible.maxY - 6))
        panel.alphaValue = 1
        panel.orderFrontRegardless()
    }

    /// Called when a hardware scan finishes: keep the panel while a Done
    /// decision is pending, otherwise fade it out after a moment.
    func scanFinished(engine: ScannerEngine) {
        guard panel?.isVisible == true else { return }
        guard !engine.documentOpen else { return }
        hideTimer?.invalidate()
        hideTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.hide() }
        }
    }

    func hide() {
        hideTimer?.invalidate()
        hideTimer = nil
        guard let panel else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            panel.animator().alphaValue = 0
        } completionHandler: {
            Task { @MainActor in
                panel.orderOut(nil)
                panel.alphaValue = 1
            }
        }
    }
}

struct ScanToastView: View {
    @Environment(ScannerEngine.self) private var engine
    let onDone: () -> Void
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            thumbnail
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if engine.status == .idle, engine.documentOpen {
                    Button("Done") { onDone() }
                        .controlSize(.small)
                        .buttonStyle(.borderedProminent)
                        .padding(.top, 2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(width: 340, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(alignment: .topTrailing) {
            Button {
                onClose()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .padding(6)
        }
        .padding(6)
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let live = engine.livePageImage {
            Image(nsImage: NSImage(cgImage: live, size: .zero))
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 52, height: 66)
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .shadow(radius: 1)
        } else if let page = engine.pages.last {
            Image(nsImage: page.thumbnail)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 52, height: 66)
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .shadow(radius: 1)
        } else {
            RoundedRectangle(cornerRadius: 4)
                .fill(.quaternary)
                .frame(width: 52, height: 66)
                .overlay {
                    Image(systemName: "doc.text")
                        .foregroundStyle(.secondary)
                }
        }
    }

    private var title: String {
        switch engine.status {
        case .scanning(let page): "Scanning page \(page)…"
        default:
            if engine.feederWasEmpty {
                "The feeder was empty"
            } else if (engine.current?.processingRemaining ?? 0) > 0 {
                "Straightening \(engine.pages.count) page\(engine.pages.count == 1 ? "" : "s")…"
            } else {
                "\(engine.pages.count) page\(engine.pages.count == 1 ? "" : "s") scanned"
            }
        }
    }

    private var subtitle: String {
        if let error = engine.lastError { return error }
        if engine.feederWasEmpty { return "Load paper and press the button again." }
        if let name = engine.documentURL?.lastPathComponent {
            return engine.documentOpen ? "\(name) — scanning adds more" : name
        }
        return "Ready"
    }
}
