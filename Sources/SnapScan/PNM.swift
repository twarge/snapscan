import CoreGraphics
import Foundation

/// Decoder for the binary PNM formats scanimage emits: P4 (1-bit), P5 (8-bit gray), P6 (24-bit RGB).
enum PNM {
    enum DecodeError: Error, LocalizedError {
        case notPNM
        case truncated
        case unsupported(String)

        var errorDescription: String? {
            switch self {
            case .notPNM: "File is not a binary PNM image"
            case .truncated: "PNM file is truncated"
            case .unsupported(let detail): "Unsupported PNM variant: \(detail)"
            }
        }
    }

    static func decode(_ data: Data) throws -> CGImage {
        var pos = data.startIndex
        guard data.count >= 2, data[pos] == UInt8(ascii: "P") else { throw DecodeError.notPNM }
        let variant = data[pos + 1]
        guard [UInt8(ascii: "4"), UInt8(ascii: "5"), UInt8(ascii: "6")].contains(variant) else {
            throw DecodeError.notPNM
        }
        pos += 2

        // Header tokens are separated by whitespace; '#' starts a comment through end of line.
        func nextToken() throws -> Int {
            var inComment = false
            var value: Int? = nil
            while pos < data.endIndex {
                let byte = data[pos]
                if inComment {
                    if byte == UInt8(ascii: "\n") { inComment = false }
                } else if byte == UInt8(ascii: "#") {
                    if value != nil { break }
                    inComment = true
                } else if byte >= UInt8(ascii: "0"), byte <= UInt8(ascii: "9") {
                    value = (value ?? 0) * 10 + Int(byte - UInt8(ascii: "0"))
                } else if byte == UInt8(ascii: " ") || byte == UInt8(ascii: "\t")
                    || byte == UInt8(ascii: "\n") || byte == UInt8(ascii: "\r") {
                    if value != nil { break }
                } else {
                    throw DecodeError.unsupported("unexpected byte in header")
                }
                pos = data.index(after: pos)
            }
            guard let v = value else { throw DecodeError.truncated }
            return v
        }

        let width = try nextToken()
        let height = try nextToken()
        var maxval = 1
        if variant != UInt8(ascii: "4") {
            maxval = try nextToken()
            guard maxval > 0, maxval <= 255 else {
                throw DecodeError.unsupported("maxval \(maxval)")
            }
        }
        // A single whitespace byte separates the header from pixel data.
        guard pos < data.endIndex else { throw DecodeError.truncated }
        pos = data.index(after: pos)

        guard width > 0, height > 0 else { throw DecodeError.unsupported("zero dimensions") }

        let bytesPerRow: Int
        let bitsPerComponent: Int
        let bitsPerPixel: Int
        let colorSpace: CGColorSpace
        // P4 packs 1=black; CGImage grayscale has 0=black, so invert via decode array.
        var decodeArray: [CGFloat]? = nil

        switch variant {
        case UInt8(ascii: "4"):
            bytesPerRow = (width + 7) / 8
            bitsPerComponent = 1
            bitsPerPixel = 1
            colorSpace = CGColorSpaceCreateDeviceGray()
            decodeArray = [1, 0]
        case UInt8(ascii: "5"):
            bytesPerRow = width
            bitsPerComponent = 8
            bitsPerPixel = 8
            colorSpace = CGColorSpaceCreateDeviceGray()
        default:
            bytesPerRow = width * 3
            bitsPerComponent = 8
            bitsPerPixel = 24
            colorSpace = CGColorSpaceCreateDeviceRGB()
        }

        let pixelCount = bytesPerRow * height
        guard data.distance(from: pos, to: data.endIndex) >= pixelCount else {
            throw DecodeError.truncated
        }
        let pixels = data.subdata(in: pos..<data.index(pos, offsetBy: pixelCount))

        guard let provider = CGDataProvider(data: pixels as CFData),
            let image = CGImage(
                width: width,
                height: height,
                bitsPerComponent: bitsPerComponent,
                bitsPerPixel: bitsPerPixel,
                bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                provider: provider,
                decode: decodeArray,
                shouldInterpolate: true,
                intent: .defaultIntent
            )
        else {
            throw DecodeError.unsupported("CGImage creation failed")
        }
        return image
    }

    static func decode(contentsOf url: URL) throws -> CGImage {
        try decode(Data(contentsOf: url))
    }
}
