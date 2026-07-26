import AppKit
import SwiftUI

/// Content of the menu bar icon's dropdown panel.
struct MenuBarPanelView: View {
    @Environment(ScannerEngine.self) private var engine
    let openMain: () -> Void
    let openSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
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

            if let page = engine.pages.last {
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
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch engine.status {
        case .detecting, .scanning, .processing:
            ProgressView().controlSize(.small)
        case .noScanner:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
        case .idle:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        }
    }

    private var statusTitle: String {
        switch engine.status {
        case .detecting: "Looking for scanner…"
        case .scanning(let page): "Scanning page \(page)…"
        case .processing(let page): "Straightening page \(page)…"
        case .noScanner: "Scanner not found"
        case .idle: engine.scannerName ?? "Ready"
        }
    }
}
