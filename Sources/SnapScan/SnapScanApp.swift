import AppKit
import SwiftUI

/// Applies the activation policy, closes the initial window in menu-bar-only
/// mode, and owns the hardware-scan toast panel.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let toast = ScanToastController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let engine = ScannerEngine.shared
        let menuBarOnly = engine.settings.menuBarOnly

        NSApp.setActivationPolicy(menuBarOnly ? .accessory : .regular)
        MenuBarController.shared.setVisible(menuBarOnly)
        if !menuBarOnly {
            NSApp.activate(ignoringOtherApps: true)
        }

        engine.onHardwareScanStarted = { [weak self] in
            guard ScannerEngine.shared.settings.menuBarOnly else { return }
            self?.toast.show(engine: ScannerEngine.shared)
        }
        engine.onHardwareScanFinished = { [weak self] in
            self?.toast.scanFinished(engine: ScannerEngine.shared)
            // The file isn't final when the paper stops: straightening, the
            // text layer and the save all still have to drain before there's
            // anything worth pointing someone at.
            Task { @MainActor in
                let engine = ScannerEngine.shared
                let pages = engine.pages.count
                try? await engine.settle()
                guard let url = engine.documentURL, pages > 0 else { return }
                await ScanNotifier.shared.scanFinished(url: url, pages: pages)
            }
        }
        ScanNotifier.shared.start()

        if menuBarOnly {
            // The WindowGroup opens its window on launch; a menu-bar app
            // should start with only its status item.
            DispatchQueue.main.async {
                NSApp.windows.filter(\.canBecomeMain).forEach { $0.close() }
            }
        }

        // Test hook: lets automated checks show the About panel without menu access.
        if ProcessInfo.processInfo.environment["SNAPSCAN_SHOW_ABOUT"] != nil {
            AboutPanel.show()
        }
        // Test hook: shows the hardware-scan toast for layout verification.
        if ProcessInfo.processInfo.environment["SNAPSCAN_TEST_TOAST"] != nil {
            toast.show(engine: engine)
        }
        // Test hook: starts a scan shortly after launch (needs paper loaded).
        if ProcessInfo.processInfo.environment["SNAPSCAN_TEST_SCAN"] != nil {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(3))
                await ScannerEngine.shared.scan()
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !ScannerEngine.shared.settings.menuBarOnly
    }
}

@main
struct SnapScanApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    private let engine = ScannerEngine.shared

    var body: some Scene {
        // A single-instance Window (not WindowGroup): one scanner, one
        // session — this also removes File > New Window.
        Window("SnapScan", id: "main") {
            ContentView()
                .environment(engine)
        }
        .defaultSize(width: 960, height: 640)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About SnapScan") { AboutPanel.show() }
            }
        }

        Settings {
            SettingsView()
                .environment(engine)
        }

    }
}
