import AppKit
import SwiftUI

/// Content of the menu bar icon's dropdown panel.
struct MenuBarPanelView: View {
    @Environment(ScannerEngine.self) private var engine
    @State private var library = ScanLibrary.shared
    let openMain: () -> Void
    let openSettings: () -> Void

    var body: some View {
        @Bindable var engine = engine
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                statusIcon
                VStack(alignment: .leading, spacing: 1) {
                    Text(statusTitle)
                        .font(.headline)
                        .lineLimit(1)
                    if let name = engine.documentURL?.lastPathComponent {
                        Text(name)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer()
            }

            if let live = engine.livePageImage {
                HStack(spacing: 10) {
                    Image(nsImage: NSImage(cgImage: live, size: .zero))
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(height: 88)
                        .background(Color.white)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .shadow(radius: 1)
                    Text("Scanning…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            } else if let page = engine.pages.last {
                HStack(spacing: 10) {
                    Image(nsImage: page.thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(height: 88)
                        .background(Color.white)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .shadow(radius: 1)
                    Text("\(engine.pages.count) page\(engine.pages.count == 1 ? "" : "s")"
                        + (engine.documentOpen ? "\nscanning adds more" : ""))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }

            HStack(spacing: 8) {
                if case .scanning = engine.status {
                    Button {
                        engine.cancelScan()
                    } label: {
                        Label("Stop", systemImage: "stop.fill")
                            .frame(maxWidth: .infinity)
                    }
                } else {
                    Button {
                        Task { await engine.scan() }
                    } label: {
                        Label("Scan", systemImage: "scanner")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(engine.isBusy || !engine.scannerPresent)
                }
                if engine.documentOpen, !engine.pages.isEmpty {
                    Button("Done") { engine.done() }
                        .disabled(engine.isBusy)
                }
            }

            Divider()

            // In menu-bar-only mode this panel is the whole app: without
            // these there's no way to reach a finished scan, change where
            // scans land, or flip sides without opening the window.
            Menu("Recent Scans") {
                ForEach(library.documents.prefix(5)) { document in
                    Menu(document.name) {
                        Button("Open") { NSWorkspace.shared.open(document.url) }
                        Button("Show in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([document.url])
                        }
                    }
                }
            }
            .disabled(library.documents.isEmpty)

            Picker("Sides", selection: $engine.settings.source) {
                ForEach(ScanSource.allCases) { source in
                    Text(source.label).tag(source)
                }
            }
            Picker("Colour", selection: $engine.settings.mode) {
                ForEach(ScanMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }

            Menu("Scan To") {
                Text(engine.settings.destinationPath)
                Divider()
                Button("Choose Folder…") { chooseFolder() }
                Button("Open Scans Folder") {
                    NSWorkspace.shared.open(engine.settings.destinationURL)
                }
            }

            Divider()

            HStack {
                Button("Open SnapScan") {
                    openMain()
                }
                Spacer()
                Button {
                    openSettings()
                } label: {
                    Image(systemName: "gearshape")
                }
                .help("Settings")
                Button {
                    NSApp.terminate(nil)
                } label: {
                    Image(systemName: "power")
                }
                .help("Quit SnapScan")
            }
            .controlSize(.small)
        }
        .padding(12)
        .frame(width: 280)
        .onAppear { library.refresh() }
    }

    /// The panel can be the only thing on screen in menu-bar-only mode, and
    /// an accessory app isn't frontmost when its panel opens — without
    /// activating, the open panel comes up behind whatever is.
    private func chooseFolder() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = engine.settings.destinationURL
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        engine.setDestination(url)
        library.setMonitoredFolder(engine.settings.destinationURL)
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch engine.status {
        case .detecting, .scanning:
            ProgressView().controlSize(.small)
        case .noScanner:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
        case .idle:
            if engine.isProcessingAnywhere {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
        }
    }

    private var statusTitle: String {
        switch engine.status {
        case .detecting: "Looking for scanner…"
        case .scanning(let page): "Scanning page \(page)…"
        case .noScanner: "Scanner not found"
        case .idle:
            engine.isProcessingAnywhere
                ? "Straightening…"
                : engine.scannerName ?? "Ready"
        }
    }
}
