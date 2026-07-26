import AppKit

/// Shows the standard About panel with a license notice in the credits area.
@MainActor
enum AboutPanel {
    static func show() {
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "SnapScan",
            .applicationVersion: "1.0",
            .version: "",
            .credits: credits(),
        ])
        NSApp.activate(ignoringOtherApps: true)
    }

    private static func credits() -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.paragraphSpacing = 6

        let body: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraph,
        ]
        let secondary: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: paragraph,
        ]

        let text = NSMutableAttributedString()
        text.append(
            NSAttributedString(
                string: "Scans documents with a Fujitsu ScanSnap iX500.\n\n",
                attributes: body))
        text.append(
            NSAttributedString(
                string: """
                    SnapScan is free software: you can redistribute it and/or modify it \
                    under the terms of the GNU General Public License as published by the \
                    Free Software Foundation, either version 2 of the License, or (at your \
                    option) any later version. It is distributed WITHOUT ANY WARRANTY; \
                    see the license for details.\n\n
                    """,
                attributes: secondary))
        text.append(
            NSAttributedString(
                string: "Bundles sane-backends 1.4.0 (",
                attributes: secondary))
        text.append(link("GPL-2.0-or-later", url: gplURL, attributes: secondary))
        text.append(NSAttributedString(string: ") and libusb 1.0.27 (", attributes: secondary))
        text.append(link("LGPL-2.1-or-later", url: lgplURL, attributes: secondary))
        text.append(
            NSAttributedString(
                string: ").\nLicense texts are included in the app bundle.",
                attributes: secondary))
        return text
    }

    /// Prefer the copies shipped inside the bundle; fall back to gnu.org.
    private static var gplURL: URL {
        bundledLicense("LICENSE")
            ?? URL(string: "https://www.gnu.org/licenses/old-licenses/gpl-2.0.txt")!
    }

    private static var lgplURL: URL {
        bundledLicense("LGPL-2.1.txt")
            ?? URL(string: "https://www.gnu.org/licenses/old-licenses/lgpl-2.1.txt")!
    }

    private static func bundledLicense(_ name: String) -> URL? {
        guard let resources = Bundle.main.resourceURL else { return nil }
        let url = resources.appendingPathComponent("licenses/\(name)")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private static func link(
        _ label: String, url: URL, attributes: [NSAttributedString.Key: Any]
    ) -> NSAttributedString {
        var linkAttributes = attributes
        linkAttributes[.link] = url
        return NSAttributedString(string: label, attributes: linkAttributes)
    }
}
