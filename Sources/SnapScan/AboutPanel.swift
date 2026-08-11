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
                string: "Scans paper documents over USB and saves them as PDFs.\n\n",
                attributes: body))
        text.append(
            NSAttributedString(
                string: """
                    Licensed under the Apache License, Version 2.0. Distributed on \
                    an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND.\n\n
                    """,
                attributes: secondary))
        text.append(NSAttributedString(string: "See the ", attributes: secondary))
        text.append(link("full license", url: licenseURL, attributes: secondary))
        text.append(
            NSAttributedString(
                string: ". The scanner is driven directly over USB; no third-party "
                    + "components are bundled.",
                attributes: secondary))
        return text
    }

    /// Prefer the copy shipped inside the bundle; fall back to apache.org.
    private static var licenseURL: URL {
        if let resources = Bundle.main.resourceURL {
            let bundled = resources.appendingPathComponent("LICENSE")
            if FileManager.default.fileExists(atPath: bundled.path) { return bundled }
        }
        return URL(string: "https://www.apache.org/licenses/LICENSE-2.0")!
    }

    private static func link(
        _ label: String, url: URL, attributes: [NSAttributedString.Key: Any]
    ) -> NSAttributedString {
        var linkAttributes = attributes
        linkAttributes[.link] = url
        return NSAttributedString(string: label, attributes: linkAttributes)
    }
}
