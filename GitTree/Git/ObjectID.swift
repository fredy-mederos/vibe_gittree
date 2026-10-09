import Foundation

/// A git object id kept inline (20 bytes) so even very large histories stay compact in memory.
/// SHA-256 repositories keep their first 40 hex digits, which git still accepts as an unambiguous prefix.
struct ObjectID: Hashable, Sendable {
    let high: UInt64
    let middle: UInt64
    let low: UInt32

    /// Parses the first 40 hex characters of `hex`.
    init?(_ hex: UnsafeBufferPointer<UInt8>) {
        guard hex.count >= 40 else { return nil }
        var high: UInt64 = 0
        var middle: UInt64 = 0
        var low: UInt32 = 0
        for i in 0..<16 {
            guard let value = Self.nibble(hex[i]) else { return nil }
            high = high << 4 | UInt64(value)
        }
        for i in 16..<32 {
            guard let value = Self.nibble(hex[i]) else { return nil }
            middle = middle << 4 | UInt64(value)
        }
        for i in 32..<40 {
            guard let value = Self.nibble(hex[i]) else { return nil }
            low = low << 4 | UInt32(value)
        }
        self.high = high
        self.middle = middle
        self.low = low
    }

    init?(hex: String) {
        var copy = hex
        guard let parsed = copy.withUTF8({ ObjectID($0) }) else { return nil }
        self = parsed
    }

    var hex: String {
        var bytes = [UInt8](repeating: 0, count: 40)
        for i in 0..<16 { bytes[i] = Self.digits[Int((high >> UInt64(60 - i * 4)) & 0xF)] }
        for i in 0..<16 { bytes[16 + i] = Self.digits[Int((middle >> UInt64(60 - i * 4)) & 0xF)] }
        for i in 0..<8 { bytes[32 + i] = Self.digits[Int((low >> UInt32(28 - i * 4)) & 0xF)] }
        return String(decoding: bytes, as: UTF8.self)
    }

    var short: String { String(hex.prefix(8)) }

    private static let digits: [UInt8] = Array("0123456789abcdef".utf8)

    @inline(__always) fileprivate static func nibble(_ c: UInt8) -> UInt8? {
        switch c {
        case 0x30...0x39: return c - 0x30
        case 0x61...0x66: return c - 0x61 + 10
        case 0x41...0x46: return c - 0x41 + 10
        default: return nil
        }
    }
}

/// Stored as its hex string, for caches on disk.
extension ObjectID: Codable {
    init(from decoder: Decoder) throws {
        let hex = try decoder.singleValueContainer().decode(String.self)
        guard let id = ObjectID(hex: hex) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Not a git object id: \(hex)"))
        }
        self = id
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(hex)
    }
}
