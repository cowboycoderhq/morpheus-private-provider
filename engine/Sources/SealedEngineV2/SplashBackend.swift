import Darwin
import Foundation
import SealedSpawnC

/// The sealed Splash child as the engine's backend. The engine starts it once
/// (sealed_bringup_start: canary, pinned spawn, reports, re-checks), waits
/// for READY, then sends one REQUEST at a time over the socketpair. Any
/// protocol or channel fault ends the engine: sessions are bound to this
/// child, so the engine fails closed and does not restart it silently.
final class SplashBackend {
    private var result = sealed_bringup_result()
    private(set) var maxContext: UInt32 = 0
    private var nextRequestId: UInt64 = 1
    private let lock = NSLock()

    var pid: pid_t { result.pid }

    init(childPath: String, decoyPath: String, package: ModelPackage, maxContext: Int, kvBudgetBytes: UInt64, logFD: Int32) throws {
        let ctx = String(maxContext)
        var why = [CChar](repeating: 0, count: 512)
        let rc: Int32 = ChildPin.cdhash.withUnsafeBufferPointer { cd in
            ChildPin.decoyCDHash.withUnsafeBufferPointer { dcd in
                ChildPin.requirement.withUnsafeBufferPointer { req in
                    package.manifest.withUnsafeBytes { man in
                        childPath.withCString { cp in decoyPath.withCString { dp in
                            package.root.withCString { root in ctx.withCString { mc in
                                var cfg = sealed_bringup_config(
                                    child_path: cp, decoy_path: dp,
                                    child_cdhash: cd.baseAddress, decoy_cdhash: dcd.baseAddress,
                                    requirement: req.baseAddress, requirement_len: req.count,
                                    status_word: ChildPin.statusWord,
                                    package_root: root, max_context: mc,
                                    manifest: man.bindMemory(to: UInt8.self).baseAddress, manifest_len: man.count,
                                    kv_budget_bytes: kvBudgetBytes,
                                    log_fd: logFD)
                                return sealed_bringup_start(&cfg, &result, &why, why.count)
                            } }
                        } }
                    }
                }
            }
        }
        guard rc == 0 else { throw BackendError.bringup(String(cString: why)) }
        guard Data(Swift.withUnsafeBytes(of: result.manifest_hash) { Data($0) }) == package.manifestHash else {
            sealed_bringup_stop(&result)
            throw BackendError.bringup("manifest hash from bring-up differs from the package's")
        }
        // READY comes after "loaded".
        let (type, payload) = try readFrame(timeoutMs: 120_000)
        guard case .ready(_, let maxConcurrent, let maxCtx, _) = try SplashWire.decode(type: type, payload: payload) else {
            throw BackendError.protocolFault("first frame after loaded is not READY")
        }
        guard maxConcurrent >= 1, maxCtx >= 1024 else { throw BackendError.protocolFault("READY limits out of range") }
        self.maxContext = maxCtx
    }

    struct Completion { let tokens: [Int]; let reason: SplashWire.FinishReason; let promptTokens: UInt32 }

    /// One generation. Re-checks the child's identity first, then sends the
    /// request and collects TOKENS until DONE.
    func generate(prompt: [Int], maxTokens: Int, temperature: Float, deadlineSeconds: Double = 300) throws -> Completion {
        lock.lock(); defer { lock.unlock() }
        guard ChildPin.cdhash.withUnsafeBufferPointer({ sealed_bringup_recheck(&result, $0.baseAddress, ChildPin.statusWord) }) == 0 else {
            throw BackendError.identity
        }
        guard prompt.count < Int(maxContext) else { throw BackendError.request("prompt longer than the context") }
        let id = nextRequestId; nextRequestId += 1
        let now = UInt64(Date().timeIntervalSince1970 * 1_000_000)
        let micros = UInt64(deadlineSeconds * 1_000_000)
        let req = SplashWire.Request(
            requestId: id, absoluteDeadlineMicros: now + micros, remainingDeadlineMicros: micros,
            maxOutputTokens: UInt32(max(1, min(maxTokens, Int(maxContext) - prompt.count))),
            promptTokens: prompt.map { UInt32($0) }, temperature: temperature,
            topK: temperature > 0 ? 20 : 0, seed: UInt64.random(in: 1...UInt64.max))
        try writeAll(try SplashWire.encode(req))
        var out: [Int] = []
        while true {
            let (type, payload) = try readFrame(timeoutMs: Int32(deadlineSeconds * 1000) + 30_000)
            switch try SplashWire.decode(type: type, payload: payload) {
            case .tokens(let rid, _, let toks) where rid == id: out += toks.map { Int($0) }
            case .done(let rid, let reason, let pt, _, _) where rid == id: return Completion(tokens: out, reason: reason, promptTokens: pt)
            // Request id 0 is a connection-level error; any other id must be ours.
            // A retryable child refusal (KV budget, capacity) is a 503 the
            // consumer can act on; anything else stays an internal failure.
            case .error(let rid, let retryable, let code, let message) where rid == id || rid == 0:
                if retryable || message.contains("KV budget exceeded") { throw BackendError.refused(message) }
                throw BackendError.request("engine error \(code): \(message)")
            case .capacityExhausted(let rid, _) where rid == id: throw BackendError.refused("capacity exhausted")
            case .start(let rid, _, _) where rid == id: continue
            case .progress(let rid, _) where rid == id: continue
            case .other: continue
            default: throw BackendError.protocolFault("frame for another request")
            }
        }
    }

    func stop() { sealed_bringup_stop(&result) }

    /// Liveness and identity of the child (sealed_bringup_alive), without the
    /// generation lock: a generation holds it for minutes, and /attest must not
    /// wait. `result` is written only in init and stop, so a copy is safe here.
    func checkAlive() throws {
        var why = [CChar](repeating: 0, count: 300)
        let snapshot = result
        let rc = withUnsafePointer(to: snapshot) { r in
            ChildPin.cdhash.withUnsafeBufferPointer { sealed_bringup_alive(r, $0.baseAddress, ChildPin.statusWord, &why, why.count) }
        }
        guard rc == 0 else { throw BackendError.dead(String(cString: why)) }
    }

    private func writeAll(_ d: Data) throws {
        try d.withUnsafeBytes { buf in
            var off = 0
            while off < buf.count {
                let w = write(result.channel_fd, buf.baseAddress! + off, buf.count - off)
                if w < 0 && errno == EINTR { continue }
                guard w > 0 else { throw BackendError.channel("write failed errno=\(errno)") }
                off += w
            }
        }
    }

    private func readExact(_ n: Int, timeoutMs: Int32) throws -> Data {
        var data = Data(count: n)
        var off = 0
        while off < n {
            var pfd = pollfd(fd: result.channel_fd, events: Int16(POLLIN), revents: 0)
            let pr = poll(&pfd, 1, timeoutMs)
            if pr < 0 && errno == EINTR { continue }
            guard pr > 0 else { throw BackendError.channel("timeout") }
            let r = data.withUnsafeMutableBytes { read(result.channel_fd, $0.baseAddress! + off, n - off) }
            if r < 0 && errno == EINTR { continue }
            guard r > 0 else { throw BackendError.channel("channel closed") }
            off += r
        }
        return data
    }

    private func readFrame(timeoutMs: Int32) throws -> (UInt16, Data) {
        let (type, n) = try SplashWire.parseHeader(try readExact(SplashWire.headerBytes, timeoutMs: timeoutMs))
        return (type, n == 0 ? Data() : try readExact(n, timeoutMs: timeoutMs))
    }
}

enum BackendError: Error { case bringup(String), protocolFault(String), channel(String), request(String), refused(String), identity, dead(String) }
