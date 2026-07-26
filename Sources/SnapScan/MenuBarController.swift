import AppKit
import SwiftUI

/// Captures SwiftUI's openWindow action (from ContentView) so AppKit-side
/// code can reopen the main window after it has been closed.
@MainActor
final class WindowOpener {
    static let shared = WindowOpener()
    var openWindowAction: OpenWindowAction?

    func openMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: \.canBecomeMain) {
            window.makeKeyAndOrderFront(nil)
        } else if let openWindowAction {
            openWindowAction(id: "main")
        }
    }
}

/// Owns the menu bar status item and its dropdown popover. Implemented with
/// NSStatusItem directly (not MenuBarExtra) so visibility is deterministic
/// and the panel could also be opened programmatically.
@MainActor
final class MenuBarController: NSObject {
    static let shared = MenuBarController()

    private var statusItem: NSStatusItem?
    private let popover = NSPopover()

    func setVisible(_ visible: Bool) {
        if visible {
            guard statusItem == nil else { return }
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            item.button?.image = NSImage(
                systemSymbolName: "scanner", accessibilityDescription: "SnapScan")
            item.button?.target = self
            item.button?.action = #selector(togglePopover)
            statusItem = item

            popover.behavior = .transient
            popover.contentViewController = NSHostingController(
                rootView: MenuBarPanelView(
                    openMain: { [weak self] in
                        self?.popover.performClose(nil)
                        WindowOpener.shared.openMainWindow()
                    },
                    openSettings: { [weak self] in
                        self?.popover.performClose(nil)
                        NSApp.activate(ignoringOtherApps: true)
                        // SwiftUI's Settings scene responds to this action.
                        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                    }
                )
                .environment(ScannerEngine.shared))
        } else {
            popover.performClose(nil)
            if let statusItem {
                NSStatusBar.system.removeStatusItem(statusItem)
            }
            statusItem = nil
        }
    }

    @objc private func togglePopover() {
        guard let button = statusItem?.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }
}
