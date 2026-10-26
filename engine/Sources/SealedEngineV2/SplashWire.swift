import Foundation

/// Splash native protocol v6 (the subset the engine uses), byte for byte as
/// /opt/homebrew/opt/splash/libexec/server/protocol.py: little-endian, a
/// 24-byte header "SPLH" | u16 version | u16 header bytes | u16 type |
/// u16 flags (0) | u64 payload bytes | u32 reserved (0), then the payload.
enum SplashWire {
    static let magic: [UInt8] = Array("SPLH".utf8)
    static let version: UInt16 = 6
    static let headerBytes = 24
    static let maxPayload: UInt64 = 256 * 1024 * 1024
    static let maxTopK: UInt32 = 32

    enum FrameType: UInt16 {
        case request = 0x0001, cancel = 0x0002, maskResponse = 0x0003, statusRequest = 0x0004
        case ready = 0x0100, start = 0x0101, tokens = 0x0102, maskRequest = 0x0103
        case done = 0x0104, error = 0x0105, capacityExhausted = 0x0106, statusJSON = 0x0107
        case promptProgress = 0x0108
    }

    enum FinishReason: UInt8 { case stop = 0, length = 1, cancelled = 2 }

    struct Request {
        var requestId: UInt64
        var priority: UInt8 = 0            // FOREGROUND
        var absoluteDeadlineMicros: UInt64
        var remainingDeadlineMicros: UInt64
        var maxOutputTokens: UInt32
        var promptTokens: [UInt32]
        var temperature: Float
        var topP: Float = 1.0
        var topK: UInt32
        var seed: UInt64
        var returnProgress = false

        /// Cohort follows the server's rule: GREEDY at temperature 0, else
        /// SAMPLING (constraint mode is always NONE here).
        var cohort: UInt8 { temperature > 0 ? 1 : 0 }

        func validate() throws {
            guard requestId != 0 else { throw WireError.invalid("request id must be non-zero") }
            guard absoluteDeadlineMicros != 0, remainingDeadlineMicros != 0 else { throw WireError.invalid("deadlines must be non-zero") }
            guard maxOutputTokens > 0, maxOutputTokens <= 1 << 20 else { throw WireError.invalid("max output tokens out of range") }
            guard !promptTokens.isEmpty, promptTokens.count <= 1 << 20 else { throw WireError.invalid("prompt token count out of range") }
            guard temperature.isFinite, temperature >= 0, topP.isFinite, topP > 0, topP <= 1,
                  topK <= SplashWire.maxTopK, !(temperature > 0 && topK == 0)
            else { throw WireError.invalid("sampling parameters out of range") }
        }
    }

    enum Event {
        case ready(instance: UInt64, maxConcurrent: UInt32, maxContext: UInt32, features: UInt64)
        case start(requestId: UInt64, matched: UInt32, capacity: UInt32)
        case progress(requestId: UInt64, processed: UInt32)
        case tokens(requestId: UInt64, offset: UInt32, tokens: [UInt32])
        case done(requestId: UInt64, reason: FinishReason, promptTokens: UInt32, completionTokens: UInt32, wallMicros: UInt64)
        case error(requestId: UInt64, retryable: Bool, code: String, message: String)
        case capacityExhausted(requestId: UInt64, retryAfterMicros: UInt64)
        case other(FrameType)
    }

    enum WireError: Error { case invalid(String), header(String), payload(String) }

    static func encode(_ r: Request) throws -> Data {
        try r.validate()
        var p = Data(capacity: 64 + 4 * r.promptTokens.count)
        p.le(r.requestId); p.append(r.priority); p.append(r.cohort); p.append(0) // constraint NONE
        p.le(r.absoluteDeadlineMicros); p.le(r.remainingDeadlineMicros)
        p.le(r.maxOutputTokens); p.le(UInt32(r.promptTokens.count)); p.le(UInt32(0)) // no image spans
        p.le(r.temperature.bitPattern); p.le(r.topP.bitPattern); p.le(r.topK); p.le(r.seed)
        p.append(r.returnProgress ? 1 : 0); p.le(UInt32(0))                           // no score tokens
        precondition(p.count == 64)
        for t in r.promptTokens { p.le(t) }
        return header(.request, payload: p.count) + p
    }

    static func header(_ type: FrameType, payload: Int) -> Data {
        var h = Data(magic)
        h.le(version); h.le(UInt16(headerBytes)); h.le(type.rawValue); h.le(UInt16(0))
        h.le(UInt64(payload)); h.le(UInt32(0))
        return h
    }

    /// Parses a header; returns the frame type and payload length.
    static func parseHeader(_ h: Data) throws -> (UInt16, Int) {
        guard h.count == headerBytes, Array(h.prefix(4)) == magic else { throw WireError.header("bad magic") }
        guard h.u16(4) == version, h.u16(6) == UInt16(headerBytes) else { throw WireError.header("unsupported version or header size") }
        guard h.u16(10) == 0, h.u32(20) == 0 else { throw WireError.header("flags and reserved must be zero") }
        let n = h.u64(12)
        guard n <= maxPayload else { throw WireError.header("payload too large") }
        return (h.u16(8), Int(n))
    }

    static func decode(type raw: UInt16, payload p: Data) throws -> Event {
        guard let type = FrameType(rawValue: raw) else { throw WireError.payload("unknown frame type \(raw)") }
        func need(_ n: Int) throws { guard p.count >= n else { throw WireError.payload("short \(type) payload") } }
        switch type {
        case .ready:
            try need(24)
            return .ready(instance: p.u64(0), maxConcurrent: p.u32(8), maxContext: p.u32(12), features: p.u64(16))
        case .start:
            try need(21)
            return .start(requestId: p.u64(0), matched: p.u32(13), capacity: p.u32(17))
        case .promptProgress:
            try need(20)
            return .progress(requestId: p.u64(0), processed: p.u32(8))
        case .tokens:
            try need(16)
            let count = Int(p.u32(12))
            guard count <= 4096, p.count == 16 + 4 * count else { throw WireError.payload("bad tokens payload") }
            return .tokens(requestId: p.u64(0), offset: p.u32(8), tokens: (0..<count).map { p.u32(16 + 4 * $0) })
        case .done:
            try need(41)
            guard let reason = FinishReason(rawValue: p[p.startIndex + 8]) else { throw WireError.payload("bad finish reason") }
            return .done(requestId: p.u64(0), reason: reason, promptTokens: p.u32(9), completionTokens: p.u32(13), wallMicros: p.u64(33))
        case .error:
            try need(18)
            let cl = Int(p.u32(10)), ml = Int(p.u32(14))
            guard cl <= 1 << 20, ml <= 1 << 20, p.count == 18 + cl + ml else { throw WireError.payload("bad error payload") }
            let code = String(decoding: p.subdata(in: p.startIndex + 18 ..< p.startIndex + 18 + cl), as: UTF8.self)
            let msg = String(decoding: p.subdata(in: p.startIndex + 18 + cl ..< p.startIndex + 18 + cl + ml), as: UTF8.self)
            return .error(requestId: p.u64(2), retryable: p[p.startIndex + 1] != 0, code: code, message: msg)
        case .capacityExhausted:
            try need(24)
            return .capacityExhausted(requestId: p.u64(0), retryAfterMicros: p.u64(16))
        default:
            return .other(type)
        }
    }
}

extension Data {
    mutating func le<T: FixedWidthInteger>(_ v: T) {
        var x = v.littleEndian
        Swift.withUnsafeBytes(of: &x) { append(contentsOf: $0) }
    }
    func u16(_ o: Int) -> UInt16 { UInt16(self[startIndex + o]) | UInt16(self[startIndex + o + 1]) << 8 }
    func u32(_ o: Int) -> UInt32 { (0..<4).reduce(UInt32(0)) { $0 | UInt32(self[startIndex + o + $1]) << (8 * UInt32($1)) } }
    func u64(_ o: Int) -> UInt64 { (0..<8).reduce(UInt64(0)) { $0 | UInt64(self[startIndex + o + $1]) << (8 * UInt64($1)) } }
}
