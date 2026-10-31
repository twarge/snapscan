import CoreGraphics
import Foundation

// MARK: - Recording

/// Keeps every exchange with the scanner during a diagnostics run, for the
/// report's transcript: the command, its status packet, and the leading bytes
/// of each data phase. Image data is cut to a few bytes — enough to tell raw
/// pixels from a compressed stream, never enough to show what was on a page.
///
/// What it records are first-hand observations of the customer's scanner,
/// the same standing as the captures docs/PROTOCOL.md was written from.
nonisolated final class TransferRecorder: @unchecked Sendable {
    struct Exchange: Sendable {
        let cdb: [UInt8]
        let dataOutCount: Int
        /// The leading bytes of what was sent.
        let dataOut: [UInt8]
        let requested: Int
        let receivedCount: Int
        /// The leading bytes of what came back.
        let received: [UInt8]
        let statusPacket: [UInt8]
        let error: String?
        /// Consecutive identical exchanges collapse into one, counted here —
        /// a sensor polled while waiting for a button press, say.
        var repeats = 1
        var elapsed: Duration

        func isRepeat(of other: Exchange) -> Bool {
            cdb == other.cdb && dataOut == other.dataOut && dataOutCount == other.dataOutCount
                && requested == other.requested && receivedCount == other.receivedCount
                && received == other.received && statusPacket == other.statusPacket
                && error == other.error
        }

        var isImageRead: Bool {
            cdb.count > 2 && cdb[0] == ScannerCommands.Opcode.read.rawValue
                && cdb[2] == ScannerCommands.ReadType.image.rawValue
        }

        /// Status byte 9 (docs/PROTOCOL.md §2), in words.
        var statusSummary: String {
            if let error { return "failed: \(error)" }
            guard statusPacket.count > 9 else { return "no status" }
            switch statusPacket[9] {
            case 0x00: return "good"
            case 0x02: return "check condition"
            case let other: return String(format: "status 0x%02x", other)
            }
        }
    }

    struct Step: Sendable {
        let name: String
        var exchanges: [Exchange] = []
        /// Past `detailLimit`, exchanges are only counted, by kind.
        var tally: [String: Int] = [:]
    }

    static let detailLimit = 300
    static let keptBytes = 256
    static let keptImageBytes = 16

    private let lock = NSLock()
    private var steps: [Step] = []

    /// Starts a new section of the transcript.
    func begin(step name: String) {
        lock.lock()
        defer { lock.unlock() }
        steps.append(Step(name: name))
    }

    func record(
        cdb: [UInt8], dataOut: Data?, requested: Int, received: Data, statusPacket: Data,
        error: Error?, elapsed: Duration
    ) {
        let isImageRead =
            cdb.count > 2 && cdb[0] == ScannerCommands.Opcode.read.rawValue
            && cdb[2] == ScannerCommands.ReadType.image.rawValue
        let exchange = Exchange(
            cdb: cdb,
            dataOutCount: dataOut?.count ?? 0,
            dataOut: Array((dataOut ?? Data()).prefix(Self.keptBytes)),
            requested: requested,
            receivedCount: received.count,
            received: Array(received.prefix(isImageRead ? Self.keptImageBytes : Self.keptBytes)),
            statusPacket: Array(statusPacket),
            error: error?.localizedDescription,
            elapsed: elapsed)

        lock.lock()
        defer { lock.unlock() }
        if steps.isEmpty { steps.append(Step(name: "start")) }
        let step = steps.count - 1
        if steps[step].tally.isEmpty, let last = steps[step].exchanges.indices.last,
            exchange.isRepeat(of: steps[step].exchanges[last]) {
            steps[step].exchanges[last].repeats += 1
            steps[step].exchanges[last].elapsed += elapsed
        } else if steps[step].exchanges.count < Self.detailLimit {
            steps[step].exchanges.append(exchange)
        } else {
            steps[step].tally[Self.kind(of: exchange), default: 0] += 1
        }
    }

    var transcript: [Step] {
        lock.lock()
        defer { lock.unlock() }
        return steps
    }

    /// One line standing for every exchange of its kind past the limit.
    private static func kind(of exchange: Exchange) -> String {
        "\(ScannerCommands.name(of: exchange.cdb)) \(hex(exchange.cdb))"
            + " → \(exchange.statusSummary), \(exchange.receivedCount) bytes in"
    }
}

// MARK: - Findings

/// What a diagnostics run found, and the plain-text report made of it — the
/// file a customer sends back.
nonisolated struct DiagnosticReport: Sendable {
    enum Outcome: Sendable, Equatable {
        case accepted
        case refused(key: UInt8, asc: UInt8, ascq: UInt8)
        case failed(String)

        var isAccepted: Bool { self == .accepted }

        var summary: String {
            switch self {
            case .accepted: "accepted"
            case .refused(let key, let asc, let ascq):
                String(format: "refused, sense %02x/%02x/%02x", key, asc, ascq)
            case .failed(let message): "failed: \(message)"
            }
        }
    }

    /// One command sent to find something out, and what came back.
    struct Probe: Sendable {
        let label: String
        let outcome: Outcome
        var data = Data()
    }

    /// Who the scanner is and what it answers to, before anything moves.
    struct Identification: Sendable {
        var usb: USBTransport.DeviceDescription?
        var pipes: [USBTransport.Pipe] = []
        var connectionError: String?
        var identity: ScannerCommands.Identity?
        var probes: [Probe] = []

        var isScanner: Bool { identity?.deviceType == 6 }
        func probe(_ label: String) -> Probe? { probes.first { $0.label == label } }
    }

    /// The sensor block watched while someone does one thing to the scanner.
    struct SensorTrial: Sendable {
        let action: String
        /// Each distinct reading in the order seen; the first is the baseline.
        var readings: [Data] = []
        var skipped = false

        var sawChange: Bool { readings.count > 1 }
        /// Back where it started after a change — a press and its release.
        var returnedToBaseline: Bool { sawChange && readings.last == readings.first }

        /// Bits that differ from the baseline in any later reading.
        var changedBits: [(byte: Int, bit: Int)] {
            guard let baseline = readings.first.map(Array.init) else { return [] }
            var changed: [(byte: Int, bit: Int)] = []
            for byte in baseline.indices {
                var mask: UInt8 = 0
                for reading in readings.dropFirst() {
                    let value = Array(reading)
                    if byte < value.count { mask |= value[byte] ^ baseline[byte] }
                }
                for bit in (0..<8).reversed() where mask & (1 << bit) != 0 {
                    changed.append((byte, bit))
                }
            }
            return changed
        }
    }

    struct PageSummary: Sendable {
        let width: Int
        let height: Int
        /// Mean red, green and blue, 0–255, as the driver decoded the page.
        let means: [Double]
    }

    struct ScanTrial: Sendable {
        let label: String
        var pages: [PageSummary] = []
        var skippedSetupSteps: [String] = []
        var error: String?
        /// The verdict of the person running it on the preview; nil if
        /// they gave none.
        var looksRight: Bool?
        /// The transcript section it was recorded under.
        var step = ""
    }

    var created = Date()
    var appVersion = ""
    var systemVersion = ""
    var macModel = ""
    var identification: Identification?
    var sensorTrials: [SensorTrial] = []
    var setup: [Probe] = []
    var scans: [ScanTrial] = []
    var notes = ""
    var transcript: [TransferRecorder.Step] = []

    /// The machine the report was made on.
    static func current() -> DiagnosticReport {
        var report = DiagnosticReport()
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        report.appVersion = "\(version) (\(build))"
        report.systemVersion = ProcessInfo.processInfo.operatingSystemVersionString
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        if size > 0 {
            var model = [UInt8](repeating: 0, count: size)
            sysctlbyname("hw.model", &model, &size, nil, 0)
            report.macModel = String(decoding: model.prefix { $0 != 0 }, as: UTF8.self)
        }
        return report
    }

    static let modePageCodes = ScannerCommands.setupModePages(autoLength: false).map(\.code)
}

// MARK: - Probing

extension NativeScanner {
    /// Learns who the attached scanner is and what it answers to, without
    /// moving paper: the USB description, then TEST UNIT READY and INQUIRY.
    /// Only a device that INQUIRY calls a scanner is sent anything further —
    /// the capability page, the setup mode pages read back, and the sensors.
    func identify() -> DiagnosticReport.Identification {
        recorder?.begin(step: "identify")
        var found = DiagnosticReport.Identification()
        found.usb = USBTransport.describe(
            vendorID: Self.vendorID, preferredProductID: Self.verifiedProductID)
        guard found.usb != nil else {
            found.connectionError = "No scanner from this vendor is on USB."
            return found
        }
        do {
            found.pipes = try claim().pipes
        } catch {
            found.connectionError = error.localizedDescription
            return found
        }

        found.probes.append(probe("TEST UNIT READY", cdb: ScannerCommands.testUnitReady()))
        let inquiry = probe("INQUIRY", cdb: ScannerCommands.inquiry(), dataIn: 96)
        found.probes.append(inquiry)
        found.identity = ScannerCommands.parseInquiry(inquiry.data)
        guard found.isScanner else { return found }

        found.probes.append(
            probe(
                "INQUIRY page f0", cdb: ScannerCommands.inquiryVendorPage(), dataIn: 204))
        for code in DiagnosticReport.modePageCodes {
            found.probes.append(
                probe(
                    String(format: "MODE SENSE page %02x", code),
                    cdb: ScannerCommands.modeSense(page: code), dataIn: 0x40))
        }
        found.probes.append(
            probe("HARDWARE STATUS", cdb: ScannerCommands.hardwareStatus(), dataIn: 12))
        return found
    }

    /// One reading of the sensor block, or nil if the scanner gave none.
    func diagnosticSensors() -> Data? {
        let reading = probe("HARDWARE STATUS", cdb: ScannerCommands.hardwareStatus(), dataIn: 12)
        return reading.outcome.isAccepted && !reading.data.isEmpty ? reading.data : nil
    }

    /// Sends every step of the setup sequence, carrying on past any the
    /// scanner refuses, so the report shows all of them rather than the first.
    func checkSetup(settings: ScanSettings, windows: [ScannerCommands.Window])
        -> [DiagnosticReport.Probe]
    {
        Self.setupSteps(for: settings, windows: windows).map { step in
            do {
                let transport = try claim()
                switch try Self.run(step, on: transport) {
                case .accepted:
                    return DiagnosticReport.Probe(label: step.label, outcome: .accepted)
                case .refused(let key, let asc, let ascq):
                    return DiagnosticReport.Probe(
                        label: step.label, outcome: .refused(key: key, asc: asc, ascq: ascq))
                }
            } catch {
                close()
                return DiagnosticReport.Probe(
                    label: step.label, outcome: .failed(error.localizedDescription))
            }
        }
    }

    /// Sends one command and keeps what came back. A connection that breaks
    /// is let go, so the next probe starts on a fresh claim rather than
    /// out of step with the device.
    private func probe(_ label: String, cdb: [UInt8], dataIn: Int = 0)
        -> DiagnosticReport.Probe
    {
        do {
            let transport = try claim()
            let (status, data) = try transport.send(cdb: cdb, dataOut: nil, dataIn: dataIn)
            guard status == .checkCondition else {
                return DiagnosticReport.Probe(label: label, outcome: .accepted, data: data)
            }
            if case .other(let key, let asc, let ascq) = try Self.sense(transport), key > 0x01 {
                return DiagnosticReport.Probe(
                    label: label, outcome: .refused(key: key, asc: asc, ascq: ascq), data: data)
            }
            return DiagnosticReport.Probe(label: label, outcome: .accepted, data: data)
        } catch {
            close()
            return DiagnosticReport.Probe(label: label, outcome: .failed(error.localizedDescription))
        }
    }
}

// MARK: - Page levels

nonisolated enum ImageLevels {
    /// Mean red, green and blue of an image, 0–255, from a small rendering.
    static func means(of image: CGImage) -> [Double] {
        let width = 64
        let height = max(1, Int((Double(image.height) / Double(max(1, image.width)) * 64).rounded()))
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard
                let context = CGContext(
                    data: buffer.baseAddress, width: width, height: height,
                    bitsPerComponent: 8, bytesPerRow: width * 4,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return [] }
        var sums = [0.0, 0.0, 0.0]
        for pixel in stride(from: 0, to: pixels.count, by: 4) {
            for channel in 0..<3 { sums[channel] += Double(pixels[pixel + channel]) }
        }
        let count = Double(width * height)
        return sums.map { $0 / count }
    }
}

// MARK: - Report text

nonisolated func hex(_ bytes: some Sequence<UInt8>) -> String {
    bytes.map { String(format: "%02x", $0) }.joined(separator: " ")
}

nonisolated extension DiagnosticReport {
    /// The report as the person sending it sees it, and as it is read back.
    var text: String {
        var lines: [String] = []
        func add(_ line: String = "") { lines.append(line) }

        let stamp = ISO8601DateFormatter().string(from: created)
        add("SnapScan scanner report")
        add("Created \(stamp) · SnapScan \(appVersion) · macOS \(systemVersion) · \(macModel)")
        add()
        add("This lists the commands SnapScan sent to the scanner and the scanner's")
        add("replies. It holds no scanned images: image transfers appear only by size,")
        add("with their first \(TransferRecorder.keptImageBytes) bytes.")
        if !notes.isEmpty {
            add()
            add("Notes:")
            for line in notes.split(separator: "\n", omittingEmptySubsequences: false) {
                add("  \(line)")
            }
        }

        add()
        add("SUMMARY")
        for (label, value) in summary {
            add("  " + label.padding(toLength: 13, withPad: " ", startingAt: 0) + value)
        }

        if let identification {
            add()
            add("USB DEVICE")
            if let usb = identification.usb {
                add(
                    String(format: "  vendor 0x%04x", usb.vendorID)
                        + (usb.vendorName.map { " \"\($0)\"" } ?? "")
                        + String(format: ", product 0x%04x", usb.productID)
                        + (usb.productName.map { " \"\($0)\"" } ?? ""))
                add(
                    "  release " + (usb.release.map { String(format: "0x%04x", $0) } ?? "?")
                        + ", " + Self.speedName(usb.speed))
                if let interfaceClass = usb.interfaceClass {
                    add(
                        String(
                            format: "  interface class 0x%02x/0x%02x/0x%02x", interfaceClass,
                            usb.interfaceSubclass ?? 0, usb.interfaceProtocol ?? 0))
                }
            } else {
                add("  none found")
            }
            if !identification.pipes.isEmpty {
                add(
                    "  endpoints: "
                        + identification.pipes.map { pipe in
                            String(format: "0x%02x ", pipe.address)
                                + Self.transferTypeName(pipe.transferType)
                                + (pipe.address & 0x80 != 0 ? " in" : " out")
                                + " (\(pipe.maxPacketSize))"
                        }.joined(separator: ", "))
            }
            if let error = identification.connectionError {
                add("  connection: \(error)")
            }

            add()
            add("IDENTITY")
            for probe in identification.probes {
                add("  " + probe.label.padding(toLength: 20, withPad: " ", startingAt: 0)
                    + probe.outcome.summary
                    + (probe.data.isEmpty ? "" : ", \(probe.data.count) bytes"))
                for row in Self.hexDump(probe.data) { add("    " + row) }
            }
        }

        if !sensorTrials.isEmpty {
            add()
            add("SENSORS (vendor 0xc2 block)")
            for trial in sensorTrials {
                add("  \(trial.action)\(trial.skipped && !trial.sawChange ? " — skipped" : "")")
                for (index, reading) in trial.readings.enumerated() {
                    add("    " + (index == 0 ? "baseline " : "then     ") + hex(reading))
                }
                let bits = trial.changedBits
                if !bits.isEmpty {
                    add("    changed: " + bits.map { "byte \($0.byte) bit \($0.bit)" }
                        .joined(separator: ", "))
                }
            }
        }

        if !setup.isEmpty {
            add()
            add("SETUP SEQUENCE (as captured from the iX500, docs/PROTOCOL.md §7)")
            for step in setup {
                add("  " + step.label.padding(toLength: 20, withPad: " ", startingAt: 0)
                    + step.outcome.summary)
            }
        }

        if !scans.isEmpty {
            add()
            add("TEST SCANS")
            for scan in scans {
                add("  \(scan.label)")
                if let error = scan.error { add("    error: \(error)") }
                if !scan.skippedSetupSteps.isEmpty {
                    add("    went on without: " + scan.skippedSetupSteps.joined(separator: ", "))
                }
                for (index, page) in scan.pages.enumerated() {
                    add(
                        "    page \(index + 1): \(page.width) × \(page.height), mean R/G/B "
                            + page.means.map { String(format: "%.0f", $0) }
                            .joined(separator: "/"))
                }
                for (window, bytes) in firstImageBytes(in: scan.step) {
                    add(String(format: "    first image bytes, window %02x: ", window) + hex(bytes))
                }
                if let looksRight = scan.looksRight {
                    add("    preview: " + (looksRight ? "looks right" : "looks wrong")
                        + " to the person running it")
                }
            }
        }

        add()
        add("TRANSCRIPT")
        for step in transcript {
            add()
            add("  — \(step.name) —")
            for (index, exchange) in step.exchanges.enumerated() {
                for line in Self.describe(exchange, number: index + 1) { add(line) }
            }
            if !step.tally.isEmpty {
                add("  … then, counted only:")
                for (kind, count) in step.tally.sorted(by: { $0.value > $1.value }) {
                    add("    \(count) × \(kind)")
                }
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// The headline of each section, label and finding.
    var summary: [(String, String)] {
        var rows: [(String, String)] = []
        guard let identification else { return [("Scanner", "not examined")] }

        let usbID = identification.usb.map {
            String(format: "USB %04x:%04x", $0.vendorID, $0.productID)
        } ?? "not on USB"
        if let identity = identification.identity {
            let firmware = identity.revision.isEmpty ? "" : ", firmware \(identity.revision)"
            let tested =
                identification.usb?.productID == NativeScanner.verifiedProductID
                ? "" : " — not yet tested with SnapScan"
            rows.append(
                ("Scanner", "\(identity.vendor) \(identity.model)\(firmware) (\(usbID))\(tested)"))
            if !identification.isScanner {
                rows.append(
                    ("Identity", "INQUIRY reports device type \(identity.deviceType), not a scanner"))
            }
        } else {
            rows.append(("Scanner", identification.connectionError ?? "did not identify itself (\(usbID))"))
        }

        let modePages = identification.probes.filter { $0.label.hasPrefix("MODE SENSE") }
        if !modePages.isEmpty {
            let answered = modePages.filter(\.outcome.isAccepted).count
            rows.append(("Mode pages", "\(answered) of \(modePages.count) read back"))
        }

        for trial in sensorTrials {
            let finding: String
            if trial.sawChange {
                finding = "change seen: "
                    + trial.changedBits.map { "byte \($0.byte) bit \($0.bit)" }
                    .joined(separator: ", ")
            } else {
                finding = trial.skipped ? "skipped, no change seen" : "no change seen"
            }
            rows.append((trial.action.components(separatedBy: ":").first ?? trial.action, finding))
        }

        if !setup.isEmpty {
            let refused = setup.filter { !$0.outcome.isAccepted }
            rows.append(
                (
                    "Setup",
                    refused.isEmpty
                        ? "all \(setup.count) steps accepted"
                        : "\(refused.count) of \(setup.count) steps not accepted: "
                            + refused.map(\.label).joined(separator: ", ")
                ))
        }

        for scan in scans {
            var finding: String
            if scan.pages.isEmpty {
                finding = scan.error ?? "no pages"
            } else {
                finding = "\(scan.pages.count) page\(scan.pages.count == 1 ? "" : "s")"
                if let first = scan.pages.first {
                    finding += ", \(first.width) × \(first.height), mean "
                        + first.means.map { String(format: "%.0f", $0) }.joined(separator: "/")
                }
                if let error = scan.error { finding += " — then: \(error)" }
            }
            if let looksRight = scan.looksRight {
                finding += looksRight ? " — looks right" : " — looks wrong"
            }
            rows.append((scan.label.components(separatedBy: ",").first ?? scan.label, finding))
        }
        return rows
    }

    /// The opening bytes of the first successful image read of each window
    /// in one transcript section: `ff d8` there would mean JPEG.
    func firstImageBytes(in stepName: String) -> [(window: UInt8, bytes: [UInt8])] {
        guard let step = transcript.first(where: { $0.name == stepName }) else { return [] }
        var seen: [(window: UInt8, bytes: [UInt8])] = []
        for exchange in step.exchanges where exchange.isImageRead {
            let window = exchange.cdb.count > 5 ? exchange.cdb[5] : 0
            guard exchange.statusSummary == "good", !exchange.received.isEmpty,
                !seen.contains(where: { $0.window == window })
            else { continue }
            seen.append((window, exchange.received))
        }
        return seen
    }

    private static func describe(_ exchange: TransferRecorder.Exchange, number: Int) -> [String] {
        let name = ScannerCommands.name(of: exchange.cdb)
        var head = String(format: "  %4d  ", number)
            + name.padding(toLength: 17, withPad: " ", startingAt: 0)
            + hex(exchange.cdb)
        if exchange.dataOutCount > 0 { head += "  out \(exchange.dataOutCount)" }
        if exchange.requested > 0 { head += "  in \(exchange.receivedCount)/\(exchange.requested)" }
        head += "  \(exchange.statusSummary)"
        if exchange.repeats > 1 { head += "  ×\(exchange.repeats)" }
        let milliseconds = Double(exchange.elapsed.components.attoseconds) / 1e15
            + Double(exchange.elapsed.components.seconds) * 1000
        head += String(format: "  %.0f ms", milliseconds)

        var lines = [head]
        // A status packet with anything beyond its tag and flag set is worth
        // seeing whole.
        let status = exchange.statusPacket
        if status.enumerated().contains(where: { $0.offset != 0 && $0.offset != 9 && $0.element != 0 }) {
            lines.append("          status \(hex(status))")
        }
        if !exchange.dataOut.isEmpty {
            for row in wrapped(exchange.dataOut) { lines.append("          > " + row) }
        }
        if !exchange.received.isEmpty {
            for row in wrapped(exchange.received) { lines.append("          < " + row) }
        }
        return lines
    }

    private static func wrapped(_ bytes: [UInt8], width: Int = 32) -> [String] {
        stride(from: 0, to: bytes.count, by: width).map {
            hex(bytes[$0..<min($0 + width, bytes.count)])
        }
    }

    /// Offset, hex and printable text, sixteen bytes a row.
    static func hexDump(_ data: Data) -> [String] {
        let bytes = [UInt8](data)
        return stride(from: 0, to: bytes.count, by: 16).map { start in
            let row = bytes[start..<min(start + 16, bytes.count)]
            let text = String(row.map { (0x20...0x7E).contains($0) ? Character(UnicodeScalar($0)) : "." })
            return String(format: "%04x  ", start)
                + hex(row).padding(toLength: 48, withPad: " ", startingAt: 0) + " " + text
        }
    }

    private static func speedName(_ speed: Int?) -> String {
        switch speed {
        case 0: "low speed (1.5 Mb/s)"
        case 1: "full speed (12 Mb/s)"
        case 2: "high speed (480 Mb/s)"
        case 3: "SuperSpeed (5 Gb/s)"
        case 4: "SuperSpeed+ (10 Gb/s)"
        case let other?: "speed \(other)"
        case nil: "speed unknown"
        }
    }

    private static func transferTypeName(_ type: UInt8) -> String {
        switch type {
        case 0: "control"
        case 1: "isochronous"
        case 2: "bulk"
        case 3: "interrupt"
        default: "type \(type)"
        }
    }
}
