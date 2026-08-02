import AppKit
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @Environment(ScannerEngine.self) private var engine
    @State private var loginItemError: String?

    var body: some View {
        @Bindable var engine = engine
        Form {
            Section("Scan") {
                Picker("Sides", selection: $engine.settings.source) {
                    ForEach(ScanSource.allCases) { source in
                        Text(source.label).tag(source)
                    }
                }
                Picker("Color", selection: $engine.settings.mode) {
                    ForEach(ScanMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                Picker("Resolution", selection: $engine.settings.resolution) {
                    ForEach(ScanSettings.resolutions, id: \.self) { dpi in
                        Text("\(dpi) dpi").tag(dpi)
                    }
                }
                Picker("Paper", selection: $engine.settings.paperSize) {
                    ForEach(PaperSize.allCases) { size in
                        Text(size.rawValue).tag(size)
                    }
                }
            }
            Section("Cleanup") {
                Toggle("Straighten pages", isOn: $engine.settings.deskew)
                Toggle("Crop to content", isOn: $engine.settings.autocrop)
                Toggle("Skip blank pages", isOn: $engine.settings.skipBlankPages)
                Toggle("Auto-rotate pages upright", isOn: $engine.settings.autoRotate)
            }
            Section("Saving") {
                LabeledContent("Scans folder") {
                    HStack(spacing: 6) {
                        TextField("Folder", text: $engine.settings.destinationPath)
                            .textFieldStyle(.roundedBorder)
                            .frame(minWidth: 220)
                        Button {
                            chooseFolder()
                        } label: {
                            Image(systemName: "folder")
                        }
                        .help("Choose the folder scans are saved into")
                    }
                }
                Toggle("Combine scans into one document", isOn: $engine.settings.appendScans)
                Text(
                    engine.settings.appendScans
                        ? "Each scan adds pages to the current PDF until you press Done."
                        : "Each scan is saved as its own PDF."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                Toggle("Suggest a name from the document", isOn: $engine.settings.suggestNames)
                Text(
                    "Reads the first two pages and proposes a filename. "
                        + "Runs entirely on this Mac — nothing is sent anywhere. "
                        + "A name you type yourself is never replaced."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Section("Scanner") {
                Toggle(
                    "Start scanning with the scanner's Scan button",
                    isOn: $engine.settings.hardwareButton)
                Text("SnapScan checks the button about once a second while idle.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("App") {
                Toggle("Keep SnapScan only in the menu bar", isOn: $engine.settings.menuBarOnly)
                Text(
                    "Hides the Dock icon. Scans started with the scanner's button "
                        + "pop up a preview by the menu bar."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                Toggle("Start SnapScan at login", isOn: $engine.settings.launchAtLogin)
                if let loginItemError {
                    Text(loginItemError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
        .onChange(of: engine.settings.menuBarOnly) { _, menuBarOnly in
            NSApp.setActivationPolicy(menuBarOnly ? .accessory : .regular)
            MenuBarController.shared.setVisible(menuBarOnly)
            // A policy change can background the app; keep the settings window up.
            NSApp.activate(ignoringOtherApps: true)
        }
        .onChange(of: engine.settings.launchAtLogin) { _, enabled in
            applyLoginItem(enabled)
        }
    }

    private func applyLoginItem(_ enabled: Bool) {
        loginItemError = nil
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else {
                if SMAppService.mainApp.status == .enabled {
                    try SMAppService.mainApp.unregister()
                }
            }
        } catch {
            loginItemError =
                "Couldn't update the login item: \(error.localizedDescription) "
                + "(the app must run from a normal location like /Applications)"
            engine.settings.launchAtLogin = !enabled
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = engine.settings.destinationURL
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        engine.setDestination(url)
    }
}
