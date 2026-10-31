import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// Walks someone through recording how their scanner responds — a model
/// SnapScan hasn't been tested with, or one that isn't working — and saves
/// a plain-text report for them to send back. Nothing is concluded here: the
/// report carries the scanner's own answers, and reading them is left to
/// whoever receives it.
@MainActor
@Observable
final class DiagnosticsSession {
    enum Stage: Int, CaseIterable, Identifiable {
        case welcome, identify, button, paper, setup, scan, report

        var id: Int { rawValue }

        var title: String {
            switch self {
            case .welcome: "Start"
            case .identify: "Identify"
            case .button: "Scan button"
            case .paper: "Paper"
            case .setup: "Setup"
            case .scan: "Test scan"
            case .report: "Report"
            }
        }
    }

    private(set) var stage: Stage = .welcome
    private(set) var report = DiagnosticReport.current()
    /// A probe or scan is under way.
    private(set) var isWorking = false
    /// The scanner is held for diagnostics, and the engine stands aside.
    private(set) var holdsScanner = false
    private(set) var startError: String?
    /// The sensor trial being watched, as it happens.
    private(set) var watching: DiagnosticReport.SensorTrial?
    private(set) var livePreview: CGImage?
    /// The pages of each test scan, alongside `report.scans`.
    private(set) var scanImages: [[CGImage]] = []
    private(set) var savedFiles: [URL] = []
    private(set) var saveError: String?
    var notes = ""
    var includeImages = false

    private var recorder = TransferRecorder()
    private var watchTask: Task<Void, Never>?
    private let engine = ScannerEngine.shared

    static let buttonAction = "Scan button: press it once"
    static let paperAction = "Paper: load a sheet into the feeder"

    // MARK: - Flow

    func start() async {
        startError = nil
        guard engine.beginDiagnostics() else {
            startError = "SnapScan is using the scanner. Try again when the scan finishes."
            return
        }
        holdsScanner = true
        await NativeScanner.shared.setRecorder(recorder)
        stage = .identify
        isWorking = true
        report.identification = await NativeScanner.shared.identify()
        isWorking = false
    }

    func advance() async {
        switch stage {
        case .welcome:
            await start()
        case .identify:
            if report.identification?.isScanner == true {
                stage = .button
                watch(Self.buttonAction)
            } else {
                await finish()
            }
        case .button:
            await stopWatching()
            stage = .paper
            watch(Self.paperAction)
        case .paper:
            await stopWatching()
            stage = .setup
            isWorking = true
            recorder.begin(step: "setup check")
            report.setup = await NativeScanner.shared.checkSetup(
                settings: Self.testSettings(duplex: false), windows: [.front])
            isWorking = false
        case .setup:
            stage = .scan
        case .scan:
            await finish()
        case .report:
            break
        }
    }

    /// Scans whatever is in the feeder with fixed, known settings, going on
    /// past any setup step the scanner refused.
    func scan(duplex: Bool) async {
        guard holdsScanner, !isWorking else { return }
        isWorking = true
        livePreview = nil
        let label = duplex
            ? "Both sides, 300 dpi colour, Letter" : "Front side, 300 dpi colour, Letter"
        let step = "test scan \(report.scans.count + 1): \(duplex ? "both sides" : "front side")"
        recorder.begin(step: step)
        var trial = DiagnosticReport.ScanTrial(label: label, step: step)

        let pages = PageCollector()
        do {
            let result = try await NativeScanner.shared.scanBatch(
                settings: Self.testSettings(duplex: duplex), startingAtPage: 0,
                lenientSetup: true
            ) { [weak self] event in
                switch event {
                case .pageComplete(_, let image):
                    pages.append(image)
                case .pagePartial(_, let image, _):
                    Task { @MainActor in self?.livePreview = image }
                case .pageStarted:
                    break
                }
            }
            trial.skippedSetupSteps = result.skippedSetupSteps
            if result.feederWasEmpty {
                trial.error = "The feeder was empty, so nothing was scanned."
            }
        } catch {
            trial.error = error.localizedDescription
        }

        let images = pages.images
        trial.pages = images.map {
            DiagnosticReport.PageSummary(
                width: $0.width, height: $0.height, means: ImageLevels.means(of: $0))
        }
        report.scans.append(trial)
        scanImages.append(images)
        livePreview = nil
        isWorking = false
    }

    func stopScan() {
        NativeScanner.shared.cancelFlag.cancel()
    }

    func setVerdict(_ looksRight: Bool, forScan index: Int) {
        guard report.scans.indices.contains(index) else { return }
        report.scans[index].looksRight = looksRight
    }

    /// Gives the scanner back and freezes the transcript.
    func finish() async {
        await stopWatching()
        await release()
        stage = .report
    }

    /// Lets go of the scanner, if held. Safe to call more than once — the
    /// window calls it on closing, whatever stage it was at.
    func release() async {
        watchTask?.cancel()
        guard holdsScanner else { return }
        if isWorking { NativeScanner.shared.cancelFlag.cancel() }
        holdsScanner = false
        // Queued behind any scan still running on the actor, so the scan
        // ends before the recording does.
        await NativeScanner.shared.setRecorder(nil)
        report.transcript = recorder.transcript
        await engine.endDiagnostics()
    }

    func startOver() async {
        await release()
        recorder = TransferRecorder()
        report = DiagnosticReport.current()
        stage = .welcome
        scanImages = []
        savedFiles = []
        saveError = nil
        startError = nil
        notes = ""
        includeImages = false
    }

    // MARK: - Sensors

    /// Polls the sensor block while the person does `action`, keeping each
    /// distinct reading.
    private func watch(_ action: String) {
        recorder.begin(step: "sensors — \(action)")
        watching = DiagnosticReport.SensorTrial(action: action)
        watchTask = Task { [weak self] in
            while !Task.isCancelled {
                if let reading = await NativeScanner.shared.diagnosticSensors(),
                    let self, var trial = self.watching, trial.readings.last != reading {
                    trial.readings.append(reading)
                    self.watching = trial
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    private func stopWatching() async {
        watchTask?.cancel()
        // Wait out a read in flight, so it can't land in the next step.
        await watchTask?.value
        watchTask = nil
        if var trial = watching {
            trial.skipped = !trial.sawChange
            report.sensorTrials.append(trial)
        }
        watching = nil
    }

    // MARK: - Report

    var reportText: String {
        var final = report
        final.notes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        return final.text
    }

    var hasImages: Bool { scanImages.contains { !$0.isEmpty } }

    /// Writes the report — and the test pages, if asked — into the scans
    /// folder, which the app can already write to, and shows them in Finder.
    func save() {
        saveError = nil
        let folder = engine.settings.destinationURL
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let base = "SnapScan Scanner Report \(formatter.string(from: report.created))"
        var written: [URL] = []
        do {
            try FileManager.default.createDirectory(
                at: folder, withIntermediateDirectories: true)
            let reportURL = folder.appendingPathComponent(base + ".txt")
            try reportText.write(to: reportURL, atomically: true, encoding: .utf8)
            written.append(reportURL)
            if includeImages {
                for (scanIndex, images) in scanImages.enumerated() {
                    for (pageIndex, image) in images.enumerated() {
                        let url = folder.appendingPathComponent(
                            "\(base) – scan \(scanIndex + 1) page \(pageIndex + 1).png")
                        try Self.writePNG(image, to: url)
                        written.append(url)
                    }
                }
            }
        } catch {
            saveError = "Couldn't save into \(folder.path): \(error.localizedDescription)"
            return
        }
        savedFiles = written
        NSWorkspace.shared.activateFileViewerSelecting(written)
    }

    func copyReport() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(reportText, forType: .string)
    }

    private static func writePNG(_ image: CGImage, to url: URL) throws {
        guard
            let destination = CGImageDestinationCreateWithURL(
                url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { throw CocoaError(.fileWriteUnknown) }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    /// The same settings for every test scan, whatever the app is set to, so
    /// reports from different scanners can be compared.
    static func testSettings(duplex: Bool) -> ScanSettings {
        var settings = ScanSettings()
        settings.source = duplex ? .duplex : .front
        settings.mode = .color
        settings.resolution = 300
        settings.paperSize = .letter
        return settings
    }
}

/// Collects pages as the scanner actor hands them over.
nonisolated private final class PageCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var collected: [CGImage] = []

    func append(_ image: CGImage) {
        lock.lock()
        collected.append(image)
        lock.unlock()
    }

    var images: [CGImage] {
        lock.lock()
        defer { lock.unlock() }
        return collected
    }
}

// MARK: - Window

struct DiagnosticsView: View {
    static let windowID = "diagnostics"

    /// Brings the window up — also from the menu bar, where the app may be
    /// in the background.
    static func open(with openWindow: OpenWindowAction) {
        openWindow(id: windowID)
        NSApp.activate(ignoringOtherApps: true)
    }

    @Environment(ScannerEngine.self) private var engine
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var session = DiagnosticsSession()
    @State private var showingFullReport = false

    var body: some View {
        HStack(spacing: 0) {
            stageList
                .frame(width: 170)
                .background(.background.secondary)
            Divider()
            VStack(spacing: 0) {
                ScrollView {
                    stageContent
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(24)
                }
                Divider()
                footer
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
            }
        }
        .frame(minWidth: 700, minHeight: 500)
        .onDisappear {
            Task { await session.release() }
        }
    }

    // MARK: Stage list

    private var stageList: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Scanner Diagnostics")
                .font(.headline)
                .padding(.bottom, 6)
            ForEach(DiagnosticsSession.Stage.allCases) { stage in
                HStack(spacing: 8) {
                    stageIcon(stage)
                        .frame(width: 16)
                    Text(stage.title)
                        .foregroundStyle(stage == session.stage ? .primary : .secondary)
                        .fontWeight(stage == session.stage ? .semibold : .regular)
                }
            }
            Spacer()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func stageIcon(_ stage: DiagnosticsSession.Stage) -> some View {
        if stage.rawValue < session.stage.rawValue {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        } else if stage == session.stage {
            Image(systemName: "circle.inset.filled").foregroundStyle(.tint)
        } else {
            Image(systemName: "circle").foregroundStyle(.tertiary)
        }
    }

    // MARK: Stages

    @ViewBuilder
    private var stageContent: some View {
        switch session.stage {
        case .welcome: welcome
        case .identify: identify
        case .button: sensorStage(
            title: "Press the Scan button",
            body: "Press the Scan button on the scanner once. SnapScan is watching the "
                + "scanner's sensors to learn which one the button sets. Nothing is scanned.",
            seen: "Button press detected",
            waiting: "Waiting for a press…")
        case .paper: sensorStage(
            title: "Load a sheet",
            body: "Put one sheet of paper in the feeder, as you would to scan it. Use a blank "
                + "page, or one with nothing private on it — it is scanned in a later step.",
            seen: "The scanner noticed the paper",
            waiting: "Some scanners don't report this. Continue once the sheet is in.")
        case .setup: setup
        case .scan: scan
        case .report: reportStage
        }
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Make a scanner report", systemImage: "scanner")
                .font(.title2.weight(.semibold))
            Text(
                "If your scanner isn't working with SnapScan, or SnapScan calls it untested, "
                    + "this records how it responds so that support for it can be added or the "
                    + "problem found. It takes about two minutes and one sheet of paper."
            )
            VStack(alignment: .leading, spacing: 6) {
                Text("The report contains").font(.headline)
                bullet("your scanner's model, firmware version and USB details")
                bullet("the commands SnapScan sends and the scanner's replies")
                bullet("your Mac's model and macOS version")
                bullet("no scanned pictures — unless you choose to add the test page at the end")
            }
            Text("SnapScan won't start any other scan while this window is in use.")
                .font(.callout)
                .foregroundStyle(.secondary)
            scannerStatus
            if let error = session.startError {
                Text(error).foregroundStyle(.red)
            }
        }
    }

    private var scannerStatus: some View {
        HStack(spacing: 8) {
            if engine.scannerPresent {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text(engine.scannerName ?? "A scanner is connected")
            } else {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                Text("No scanner found. Connect it by USB and open its feeder to switch it on.")
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }

    private var identify: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Identifying the scanner").font(.title2.weight(.semibold))
            if session.isWorking {
                ProgressView("Asking the scanner what it is…")
            } else if let found = session.report.identification {
                VStack(alignment: .leading, spacing: 10) {
                    identificationRows(found)
                }
                if found.identity != nil, !found.isScanner {
                    Text(
                        "This device says it isn't a scanner, so SnapScan stopped there. "
                            + "You can still save the report."
                    )
                    .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private func identificationRows(_ found: DiagnosticReport.Identification) -> some View {
        if let usb = found.usb {
            checkRow(
                true, "Found on USB",
                [usb.productName, String(format: "USB %04x:%04x", usb.vendorID, usb.productID)]
                    .compactMap { $0 }.joined(separator: " · "))
        } else {
            checkRow(false, "Found on USB", found.connectionError ?? "Not found")
        }
        if found.usb != nil, let error = found.connectionError {
            checkRow(false, "Connected", error)
        }
        if let identity = found.identity {
            checkRow(
                found.isScanner, "Identified itself",
                "\(identity.vendor) \(identity.model)"
                    + (identity.revision.isEmpty ? "" : " · firmware \(identity.revision)"))
        } else if found.connectionError == nil {
            checkRow(false, "Identified itself", found.probe("INQUIRY")?.outcome.summary ?? "No answer")
        }
        if let page = found.probe("INQUIRY page f0") {
            checkRow(page.outcome.isAccepted, "Capabilities", page.outcome.isAccepted
                ? "\(page.data.count) bytes" : page.outcome.summary)
        }
        let modePages = found.probes.filter { $0.label.hasPrefix("MODE SENSE") }
        if !modePages.isEmpty {
            let answered = modePages.filter(\.outcome.isAccepted).count
            checkRow(answered > 0, "Settings pages", "\(answered) of \(modePages.count) read back")
        }
        if let sensors = found.probe("HARDWARE STATUS") {
            checkRow(sensors.outcome.isAccepted, "Sensors", sensors.outcome.isAccepted
                ? "Read" : sensors.outcome.summary)
        }
    }

    private func sensorStage(title: String, body: String, seen: String, waiting: String)
        -> some View
    {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(.title2.weight(.semibold))
            Text(body)
            HStack(spacing: 8) {
                if session.watching?.sawChange == true {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text(seen)
                } else {
                    ProgressView().controlSize(.small)
                    Text(waiting).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var setup: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Checking the setup sequence").font(.title2.weight(.semibold))
            Text(
                "SnapScan sends these commands before every scan. Each is tried on its own, "
                    + "so any the scanner doesn't accept show up here."
            )
            if session.isWorking {
                ProgressView("Sending the setup commands…")
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(session.report.setup.enumerated()), id: \.offset) { _, step in
                        checkRow(
                            step.outcome.isAccepted, step.label,
                            step.outcome.isAccepted ? "" : step.outcome.summary)
                    }
                }
                let refused = session.report.setup.filter { !$0.outcome.isAccepted }.count
                Text(
                    refused == 0
                        ? "The scanner accepted every step."
                        : "\(refused) step\(refused == 1 ? " wasn't" : "s weren't") accepted. "
                            + "The test scan goes on without \(refused == 1 ? "it" : "them")."
                )
                .foregroundStyle(.secondary)
            }
        }
    }

    private var scan: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Test scan").font(.title2.weight(.semibold))
            Text(
                "Scan the sheet you loaded. The picture stays on this Mac unless you choose "
                    + "to add it to the report. To scan again, put the sheet back in the feeder."
            )
            HStack {
                Group {
                    Button("Scan Front Side") { Task { await session.scan(duplex: false) } }
                        .buttonStyle(.borderedProminent)
                    Button("Scan Both Sides") { Task { await session.scan(duplex: true) } }
                }
                .disabled(session.isWorking || !session.holdsScanner)
                if session.isWorking {
                    Button("Stop") { session.stopScan() }
                }
            }

            if session.isWorking {
                HStack(alignment: .top, spacing: 12) {
                    ProgressView().controlSize(.small)
                    if let preview = session.livePreview {
                        pageThumbnail(preview)
                    } else {
                        Text("Scanning…").foregroundStyle(.secondary)
                    }
                }
            }

            ForEach(Array(session.report.scans.enumerated()).reversed(), id: \.offset) {
                index, trial in
                scanResult(index: index, trial: trial)
            }
        }
    }

    private func scanResult(index: Int, trial: DiagnosticReport.ScanTrial) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Scan \(index + 1): \(trial.label)").font(.headline)
            if let error = trial.error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(trial.pages.isEmpty ? .red : .secondary)
            }
            if session.scanImages.indices.contains(index), !session.scanImages[index].isEmpty {
                HStack(spacing: 8) {
                    ForEach(Array(session.scanImages[index].enumerated()), id: \.offset) {
                        _, image in
                        pageThumbnail(image)
                    }
                }
                HStack {
                    Text("Does this look like the sheet?")
                    Picker("", selection: Binding(
                        get: { trial.looksRight },
                        set: { if let value = $0 { session.setVerdict(value, forScan: index) } }
                    )) {
                        Text("Looks right").tag(Bool?.some(true))
                        Text("Looks wrong").tag(Bool?.some(false))
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }

    private func pageThumbnail(_ image: CGImage) -> some View {
        Image(decorative: image, scale: 1)
            .resizable()
            .interpolation(.medium)
            .aspectRatio(contentMode: .fit)
            .frame(height: 160)
            .border(.separator)
    }

    private var reportStage: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Your report is ready").font(.title2.weight(.semibold))
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                ForEach(Array(session.report.summary.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        Text(row.0).foregroundStyle(.secondary)
                        Text(row.1).textSelection(.enabled)
                    }
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Notes (optional)").font(.headline)
                TextField(
                    "The model printed on the scanner, what goes wrong, anything else…",
                    text: $session.notes, axis: .vertical
                )
                .lineLimit(3...6)
                .textFieldStyle(.roundedBorder)
            }
            if session.hasImages {
                Toggle("Add the test scan pictures", isOn: $session.includeImages)
                Text("Saved as PNG files next to the report. Leave this off if the sheet had anything private on it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Button("Save Report") { session.save() }
                    .buttonStyle(.borderedProminent)
                Button("Copy Report") { session.copyReport() }
            }
            if let error = session.saveError {
                Text(error).foregroundStyle(.red)
            } else if let first = session.savedFiles.first {
                VStack(alignment: .leading, spacing: 4) {
                    Label {
                        Text("Saved to \(first.deletingLastPathComponent().lastPathComponent)")
                    } icon: {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    }
                    Text("Send the report\(session.savedFiles.count > 1 ? " and pictures" : "") to SnapScan's developer.")
                        .foregroundStyle(.secondary)
                }
            }
            DisclosureGroup("Full report", isExpanded: $showingFullReport) {
                Text(session.reportText)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(.background, in: RoundedRectangle(cornerRadius: 6))
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            if session.stage != .welcome {
                Button("Start Over") { Task { await session.startOver() } }
                    .disabled(session.isWorking)
            }
            Spacer()
            switch session.stage {
            case .welcome:
                Button("Start") { Task { await session.advance() } }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!engine.scannerPresent || engine.isBusy)
            case .report:
                Button("Done") { dismissWindow(id: Self.windowID) }
                    .keyboardShortcut(.defaultAction)
            default:
                Button(continueTitle) { Task { await session.advance() } }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(session.isWorking)
            }
        }
    }

    private var continueTitle: String {
        switch session.stage {
        case .identify:
            session.report.identification?.isScanner == true ? "Continue" : "Make Report"
        case .button, .paper:
            session.watching?.sawChange == true ? "Continue" : "Skip"
        case .scan:
            "Make Report"
        default:
            "Continue"
        }
    }

    // MARK: Pieces

    private func checkRow(_ ok: Bool, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(ok ? .green : .red)
            Text(title)
            if !detail.isEmpty {
                Text(detail).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("•")
            Text(text)
        }
    }
}
