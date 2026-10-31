import Foundation
import Testing

@testable import SnapScan

/// A link that answers each opcode from a script, and REQUEST SENSE with the
/// sense of whatever last failed.
nonisolated private final class ScriptedLink: ScannerLink, @unchecked Sendable {
    /// Opcodes answered with a check condition, and the sense to give.
    var refusals: [UInt8: (key: UInt8, asc: UInt8, ascq: UInt8)] = [:]
    private var pendingSense: [UInt8]?
    private(set) var sent: [[UInt8]] = []

    func send(cdb: [UInt8], dataOut: Data?, dataIn: Int) throws -> (
        status: USBTransport.CommandStatus, data: Data
    ) {
        sent.append(cdb)
        if cdb[0] == ScannerCommands.Opcode.requestSense.rawValue {
            defer { pendingSense = nil }
            return (.good, Data(pendingSense ?? [UInt8](repeating: 0, count: 18)))
        }
        if let refusal = refusals[cdb[0]] {
            var sense = [UInt8](repeating: 0, count: 18)
            sense[0] = 0xF0
            sense[2] = refusal.key
            sense[12] = refusal.asc
            sense[13] = refusal.ascq
            pendingSense = sense
            return (.checkCondition, Data(count: dataIn))
        }
        return (.good, Data(count: dataIn))
    }
}

private func statusPacket(flag: UInt8 = 0) -> Data {
    var packet = [UInt8](repeating: 0, count: 13)
    packet[0] = 0x53
    packet[9] = flag
    return Data(packet)
}

struct DiagnosticsTests {
    @Test func identicalExchangesCollapseIntoOne() {
        let recorder = TransferRecorder()
        recorder.begin(step: "sensors")
        let reading = Data([0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0])
        for _ in 0..<50 {
            recorder.record(
                cdb: ScannerCommands.hardwareStatus(), dataOut: nil, requested: 12,
                received: reading, statusPacket: statusPacket(), error: nil,
                elapsed: .milliseconds(1))
        }
        var pressed = reading
        pressed[4] = 1
        recorder.record(
            cdb: ScannerCommands.hardwareStatus(), dataOut: nil, requested: 12,
            received: pressed, statusPacket: statusPacket(), error: nil,
            elapsed: .milliseconds(1))

        let step = recorder.transcript[0]
        #expect(step.exchanges.count == 2)
        #expect(step.exchanges[0].repeats == 50)
        #expect(step.exchanges[1].repeats == 1)
    }

    @Test func imageReadsKeepOnlyTheirFirstBytes() {
        let recorder = TransferRecorder()
        let chunk = Data(repeating: 0xAB, count: 260_100)
        recorder.record(
            cdb: ScannerCommands.read(type: .image, window: .front, length: chunk.count),
            dataOut: nil, requested: chunk.count, received: chunk,
            statusPacket: statusPacket(), error: nil, elapsed: .zero)
        recorder.record(
            cdb: ScannerCommands.inquiry(), dataOut: nil, requested: 96,
            received: Data(repeating: 0x20, count: 96), statusPacket: statusPacket(),
            error: nil, elapsed: .zero)

        let exchanges = recorder.transcript[0].exchanges
        #expect(exchanges[0].receivedCount == 260_100)
        #expect(exchanges[0].received.count == TransferRecorder.keptImageBytes)
        #expect(exchanges[1].received.count == 96)
    }

    @Test func exchangesPastTheLimitAreOnlyCounted() {
        let recorder = TransferRecorder()
        recorder.begin(step: "scan")
        for index in 0..<(TransferRecorder.detailLimit + 40) {
            // Alternating windows, as duplex reads go, so nothing collapses.
            let window: ScannerCommands.Window = index.isMultiple(of: 2) ? .front : .back
            recorder.record(
                cdb: ScannerCommands.read(type: .image, window: window, length: 7650),
                dataOut: nil, requested: 7650, received: Data(count: 7650),
                statusPacket: statusPacket(), error: nil, elapsed: .zero)
        }
        let step = recorder.transcript[0]
        #expect(step.exchanges.count == TransferRecorder.detailLimit)
        #expect(step.tally.values.reduce(0, +) == 40)
        #expect(step.tally.count == 2)
    }

    @Test func aStatusPacketInPlaceOfDataIsRecognised() {
        #expect(USBTransport.isStatusPacket(statusPacket(flag: 2), inPlaceOf: 96))
        // Asked for exactly a status packet's length: data, whatever it holds.
        #expect(!USBTransport.isStatusPacket(statusPacket(), inPlaceOf: 13))
        #expect(!USBTransport.isStatusPacket(Data(repeating: 0x53, count: 96), inPlaceOf: 96))
        var notTagged = [UInt8](statusPacket())
        notTagged[0] = 0x06
        #expect(!USBTransport.isStatusPacket(Data(notTagged), inPlaceOf: 96))
    }

    /// The order docs/PROTOCOL.md §7 records, unchanged by sharing it with
    /// the diagnostics.
    @Test func setupFollowsTheCapturedSequence() {
        var settings = ScanSettings()
        settings.paperSize = .letter
        let steps = NativeScanner.setupSteps(for: settings, windows: [.front, .back])
        #expect(steps.map { $0.cdb[0] } == [
            0x1D, 0x1C, 0x00, 0xC2, 0x1D,
            0x15, 0x15, 0x15, 0x15, 0x15, 0x15,
            0x24, 0x2A, 0xF1, 0xC2,
        ])
        #expect(steps.filter(\.optional).map(\.label) == ["sensor read", "sensor read"])
        let modePages = steps.filter { $0.cdb[0] == 0x15 }.compactMap { $0.dataOut?[4] }
        #expect(modePages == [0x3C, 0x38, 0x37, 0x39, 0x3A, 0x33])
        // Both windows' descriptors in one SET WINDOW (§5.1).
        #expect(steps[11].dataOut?.count == 8 + 64 * 2)
    }

    @Test func anIllegalRequestIsARefusal() throws {
        let link = ScriptedLink()
        link.refusals[0x15] = (0x05, 0x24, 0x00)
        let modeStep = NativeScanner.SetupStep(
            label: "mode page 39", cdb: ScannerCommands.modeSelect(parameterLength: 14),
            dataOut: Data(count: 14))
        #expect(try NativeScanner.run(modeStep, on: link) == .refused(key: 5, asc: 0x24, ascq: 0))

        let readyStep = NativeScanner.SetupStep(
            label: "test unit ready", cdb: ScannerCommands.testUnitReady())
        #expect(try NativeScanner.run(readyStep, on: link) == .accepted)
    }

    @Test func aRecoveredErrorStillCountsAsAccepted() throws {
        let link = ScriptedLink()
        link.refusals[0x00] = (0x01, 0x00, 0x00)
        let step = NativeScanner.SetupStep(label: "test unit ready", cdb: ScannerCommands.testUnitReady())
        #expect(try NativeScanner.run(step, on: link) == .accepted)
    }

    @Test func sensorTrialsNameTheBitsThatMoved() {
        var trial = DiagnosticReport.SensorTrial(action: "Scan button: press it once")
        trial.readings = [
            Data([0, 0, 0, 0, 0x00, 1]),
            Data([0, 0, 0, 0, 0x01, 1]),
            Data([0, 0, 0, 0, 0x00, 1]),
        ]
        #expect(trial.sawChange)
        #expect(trial.returnedToBaseline)
        #expect(trial.changedBits.map { [$0.byte, $0.bit] } == [[4, 0]])
    }

    @Test func theReportSummarisesWhatWasRefused() {
        var report = DiagnosticReport()
        var found = DiagnosticReport.Identification()
        found.usb = USBTransport.DeviceDescription(
            vendorID: 0x04C5, productID: 0x1234, release: 0x0100, vendorName: "FUJITSU",
            productName: "ScanSnap", speed: 2, interfaceClass: 0xFF, interfaceSubclass: 0xFF,
            interfaceProtocol: 0xFF)
        var inquiry = [UInt8](repeating: 0x20, count: 96)
        inquiry[0] = 0x06
        for (offset, byte) in "FUJITSU ".utf8.enumerated() { inquiry[8 + offset] = byte }
        for (offset, byte) in "ScanSnap Test".utf8.enumerated() { inquiry[16 + offset] = byte }
        for (offset, byte) in "0M00".utf8.enumerated() { inquiry[32 + offset] = byte }
        found.identity = ScannerCommands.parseInquiry(Data(inquiry))
        found.probes = [
            DiagnosticReport.Probe(label: "INQUIRY", outcome: .accepted, data: Data(inquiry))
        ]
        report.identification = found
        report.setup = [
            DiagnosticReport.Probe(label: "GET DEVICE ID", outcome: .accepted),
            DiagnosticReport.Probe(
                label: "mode page 39", outcome: .refused(key: 5, asc: 0x24, ascq: 0)),
        ]

        let rows = Dictionary(uniqueKeysWithValues: report.summary)
        #expect(rows["Scanner"]?.contains("ScanSnap Test, firmware 0M00") == true)
        #expect(rows["Scanner"]?.contains("not yet tested") == true)
        #expect(rows["Setup"] == "1 of 2 steps not accepted: mode page 39")

        let text = report.text
        #expect(text.contains("product 0x1234"))
        #expect(text.contains("high speed (480 Mb/s)"))
        #expect(text.contains("refused, sense 05/24/00"))
    }

    @Test func theFirstImageBytesOfEachWindowAreReported() {
        let recorder = TransferRecorder()
        recorder.begin(step: "test scan 1: both sides")
        // A not-ready read first: its junk is not image data.
        recorder.record(
            cdb: ScannerCommands.read(type: .image, window: .back, length: 100), dataOut: nil,
            requested: 100, received: Data(repeating: 0xEE, count: 100),
            statusPacket: statusPacket(flag: 2), error: nil, elapsed: .zero)
        recorder.record(
            cdb: ScannerCommands.read(type: .image, window: .front, length: 100), dataOut: nil,
            requested: 100, received: Data([0xFF, 0xD8] + [UInt8](repeating: 0, count: 98)),
            statusPacket: statusPacket(), error: nil, elapsed: .zero)
        recorder.record(
            cdb: ScannerCommands.read(type: .image, window: .back, length: 100), dataOut: nil,
            requested: 100, received: Data(repeating: 0x07, count: 100),
            statusPacket: statusPacket(), error: nil, elapsed: .zero)

        var report = DiagnosticReport()
        report.transcript = recorder.transcript
        let first = report.firstImageBytes(in: "test scan 1: both sides")
        #expect(first.map(\.window) == [0x00, 0x80])
        #expect(first[0].bytes.prefix(2) == [0xFF, 0xD8])
        #expect(first[1].bytes.allSatisfy { $0 == 0x07 })
    }
}
