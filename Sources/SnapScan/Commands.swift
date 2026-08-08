import AppKit
import SwiftUI

/// What the menu bar needs from the open window.
///
/// Routed through the focused scene rather than reaching for the engine
/// directly, because two of these can't be done from outside the view: Done
/// has to commit the name currently typed in the field, and Reveal has to
/// know which scan is selected. Going through here keeps a menu item and its
/// button doing the same thing rather than subtly different things.
struct ScanActions {
    var scan: () -> Void
    var done: () -> Void
    var discard: () -> Void
    var reveal: () -> Void
    var share: () -> Void
    var canScan: Bool
    var canFinish: Bool
    var hasDocument: Bool
    /// The file Reveal and Share would act on: the selected scan, or the one
    /// being built. nil disables both.
    var target: URL?
}

extension FocusedValues {
    @Entry var scanActions: ScanActions?
}

struct SnapScanCommands: Commands {
    @FocusedValue(\.scanActions) private var actions
    /// The same key the page grid reads, so the menu and a pinch agree.
    @AppStorage("thumbnailSize") private var thumbnailSize = 160.0

    var body: some Commands {
        // One scanner, one session: there's nothing to make new, so the
        // scanning verbs take the top of the File menu instead.
        CommandGroup(replacing: .newItem) {
            Button("Scan") { actions?.scan() }
                .keyboardShortcut("r")
                .disabled(actions?.canScan != true)
            Divider()
            Button("Done") { actions?.done() }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(actions?.canFinish != true)
            Button("Discard Scan") { actions?.discard() }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(actions?.hasDocument != true)
        }
        CommandGroup(after: .newItem) {
            Divider()
            Button("Reveal in Finder") { actions?.reveal() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(actions?.target == nil)
            Button("Share…") { actions?.share() }
                .disabled(actions?.target == nil)
            Button("Open Scans Folder") {
                NSWorkspace.shared.open(ScannerEngine.shared.settings.destinationURL)
            }
            .keyboardShortcut("o", modifiers: [.command, .shift])
        }
        CommandGroup(after: .toolbar) {
            // Pinch-to-zoom was the only way to reach this, which leaves out
            // anyone not using a trackpad.
            Button("Larger Thumbnails") {
                thumbnailSize = min(420, thumbnailSize * 1.25)
            }
            .keyboardShortcut("+", modifiers: .command)
            Button("Smaller Thumbnails") {
                thumbnailSize = max(80, thumbnailSize / 1.25)
            }
            .keyboardShortcut("-", modifiers: .command)
        }
        CommandGroup(replacing: .help) {
            Button("SnapScan Help") {
                if let url = URL(string: "https://twarge.com/snapscan/") {
                    NSWorkspace.shared.open(url)
                }
            }
        }
    }
}
