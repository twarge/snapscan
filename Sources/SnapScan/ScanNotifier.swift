import AppKit
import UserNotifications

/// Notification Center alerts for scans the user isn't watching.
///
/// Pressing the button on the scanner works whether or not SnapScan is in
/// front — in menu-bar mode there may be no window at all — so a finished
/// scan needs to say so somewhere the user will see it. The in-app toast
/// only helps when the app can draw a panel over the screen.
@MainActor
final class ScanNotifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = ScanNotifier()

    private let center = UNUserNotificationCenter.current()
    private var authorized: Bool?
    /// Files by notification id, so tapping one can act on the right scan.
    private var scans: [String: URL] = [:]

    private static let revealAction = "reveal"

    func start() {
        center.delegate = self
        center.setNotificationCategories([
            UNNotificationCategory(
                identifier: "scan",
                actions: [
                    UNNotificationAction(
                        identifier: Self.revealAction, title: "Show in Finder",
                        options: [.foreground])
                ],
                intentIdentifiers: [])
        ])
    }

    /// Announces a finished scan, unless the user is already looking at it.
    func scanFinished(url: URL, pages: Int) async {
        // Someone watching the window has just seen the pages appear; a
        // banner on top of that is noise.
        guard !NSApp.isActive else { return }
        guard await isAuthorized() else { return }

        let content = UNMutableNotificationContent()
        content.title = url.deletingPathExtension().lastPathComponent
        content.body =
            "\(pages) page\(pages == 1 ? "" : "s") saved to "
            + url.deletingLastPathComponent().lastPathComponent
        content.categoryIdentifier = "scan"
        content.sound = nil  // the scanner has already made plenty of noise

        let id = UUID().uuidString
        scans[id] = url
        try? await center.add(
            UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    /// Asks the first time there's actually something to announce, rather
    /// than greeting a new user with a permission prompt.
    private func isAuthorized() async -> Bool {
        if let authorized { return authorized }
        let granted =
            (try? await center.requestAuthorization(options: [.alert, .badge])) ?? false
        authorized = granted
        return granted
    }

    // MARK: UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let id = response.notification.request.identifier
        let action = response.actionIdentifier
        await MainActor.run {
            guard let url = scans.removeValue(forKey: id) else { return }
            if action == Self.revealAction {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } else {
                NSWorkspace.shared.open(url)
            }
        }
    }
}
