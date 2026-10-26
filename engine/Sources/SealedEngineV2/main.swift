// SealedEngineV2 — attested engine for the sealed Splash child (P9/P10).
//
// Same consumer API and envelope as the v1 engine (GET /attest, POST
// /session, POST /probe, POST /infer; proxy-router/internal/sealed and
// cmd/sealed-verify verify it unchanged). Differences from v1:
//   - no model and no Metal in this process: the pinned, sandboxed Splash
//     child runs the model, started through the sealed spawn module;
//   - the chat template and the tokenizer run here, from package bytes that
//     are read once and hashed; the session-bound "weights hash" slot carries
//     modelHash = SHA256("morpheus-sealed/v2/splash-model" ‖ manifest hash ‖
//     tokenizer hash ‖ child CD hash);
//   - the only plaintext copies of a prompt are in this process and in the
//     child; the HTTP side carries only envelope ciphertext.
import CoreServices
import CryptoKit
import DeviceCheck
import Foundation
import SealedSpawnC
import Tokenizers

// 1. R1 in this process too: fatal signals exit at once, and the
//    exception-port guard keeps crash reports (register state) from forming.
Signals.installExitHandlers()
setvbuf(stdout, nil, _IOLBF, 0)
do {
    var old = [sealed_old_port_t](repeating: sealed_old_port_t(), count: Int(SEALED_MAX_OLD_PORTS))
    var count: UInt32 = 0
    guard sealed_guard_install(&old, &count) == 0, sealed_guard_readback() == 0 else {
        FileHandle.standardError.write(Data("refusing to start: exception-port guard failed\n".utf8))
        exit(5)
    }
}

// 2. Only an allowlist of environment variables is accepted.
EnvGuard.enforce()
let env = ProcessInfo.processInfo.environment

// 3. App Attest refuses bundles LaunchServices does not know about.
LSRegisterURL(Bundle.main.bundleURL as CFURL, true)

let port = UInt16(env["SEALED_ENGINE_PORT"] ?? "") ?? 29451
let logFD: Int32 = {
    guard let p = env["SEALED_ENGINE_LOG"], !p.isEmpty else { return -1 }
    return open(p, O_WRONLY | O_CREAT | O_APPEND | O_NOFOLLOW | O_CLOEXEC, 0o600)
}()
func log(_ s: String) {
    print(s)
    if logFD >= 0 { _ = (s + "\n").withCString { write(logFD, $0, strlen($0)) } }
}

/// SEALED_KV_BUDGET_BYTES: decimal bytes for the child's chunked-KV budget.
/// Unset = 0 = frame v1 and the child's 16 GiB default. A value outside the
/// child's accepted range [256 MiB, 1 TiB] refuses the start here, before
/// the child would refuse it.
func kvBudgetFromEnv() -> UInt64 {
    guard let s = env["SEALED_KV_BUDGET_BYTES"], !s.isEmpty else { return 0 }
    guard let v = UInt64(s), v >= 256 << 20, v <= 1 << 40 else {
        FileHandle.standardError.write(Data("refusing to start: SEALED_KV_BUDGET_BYTES must be decimal bytes in [268435456, 1099511627776]\n".utf8))
        exit(4)
    }
    log("kv budget: \(v) bytes")
    return v
}

let engine = Engine()
var server: HTTPServer?  // retained for the process lifetime

engine.bootstrap(packageRoot: env["SEALED_PACKAGE"] ?? "", childDir: env["SEALED_CHILD_DIR"] ?? "",
                 decoy: env["SEALED_DECOY"] ?? "", maxContext: Int(env["SEALED_MAX_CONTEXT"] ?? "") ?? 32768,
                 kvBudgetBytes: kvBudgetFromEnv()) { error in
    if let error {
        log("bootstrap failed: \(error)")
        exit(2)
    }
    // R8: bind the loopback listener first (measured 2026-10-21: an SBPL
    // bind rule checks only the port, so the profile has no bind rule), then
    // the engine sandboxes itself before it serves; until then every request
    // gets 503. A failed self-test arm refuses to serve.
    do {
        server = try HTTPServer(port: port) { request, respond in
            guard engine.sandboxed else { return respond(503, ["error": "not ready"]) }
            engine.handle(request, respond: respond)
        }
    } catch {
        log("listen failed: \(error)")
        exit(3)
    }
    guard server?.start() == true else {
        log("listen failed: listener not ready on 127.0.0.1:\(port)")
        exit(3)
    }
    var why = [CChar](repeating: 0, count: 600)
    let r8 = (env["SEALED_PACKAGE"] ?? "").withCString { pkg in
        "\(env["SEALED_CHILD_DIR"] ?? "")/splash".withCString { child in
            var cfg = sealed_r8_config(package_root: pkg, child_path: child, child_pid: engine.childPid,
                                       port: port, log_fd: logFD)
            return sealed_r8_enter(&cfg, &why, why.count)
        }
    }
    guard r8 == 0 else {
        log("sandbox refused: \(String(cString: why))")
        exit(7)
    }
    engine.markSandboxed()
    log("sealed-engine-v2 listening on 127.0.0.1:\(port) keyId=\(engine.keyIdBase64) model=\(engine.modelHashHex) child=\(ChildPin.cdhashHex) sandbox=R8")
}
RunLoop.main.run()

final class Engine {
    private let service = DCAppAttestService.shared
    private let queue = DispatchQueue(label: "sealed-engine-v2.state")
    private var keyId = ""
    private var attestation = Data()
    private var attestClientData = Data()
    private var sessions: [String: Session] = [:]
    private var package: ModelPackage?
    private var backend: SplashBackend?
    private var weightsHash = Data(count: 32)
    private static let maxSessions = 256
    private static let sessionTTL: TimeInterval = 3600

    final class Session {
        let keys: EnvelopeKeys
        let created = Date()
        var recvSeq: UInt64 = 0
        var sendSeq: UInt64 = 0
        var generating = false
        init(keys: EnvelopeKeys) { self.keys = keys }
    }

    private let providerTag: Data = {
        let addr = (ProcessInfo.processInfo.environment["SEALED_PROVIDER_ADDR"] ?? "").lowercased()
        return Data(SHA256.hash(data: Data("morpheus-sealed/provider/v1".utf8) + Data(addr.utf8)))
    }()

    private var sandboxedFlag = false
    var sandboxed: Bool { queue.sync { sandboxedFlag } }
    func markSandboxed() { queue.sync { sandboxedFlag = true } }

    var childPid: pid_t { queue.sync { backend?.pid ?? 0 } }
    var keyIdBase64: String { queue.sync { keyId } }
    var modelHashHex: String { queue.sync { weightsHash.hex } }

    private func evictSessions() {
        let now = Date()
        sessions = sessions.filter { now.timeIntervalSince($0.value.created) < Self.sessionTTL }
        while sessions.count >= Self.maxSessions,
              let oldest = sessions.min(by: { $0.value.created < $1.value.created })?.key {
            sessions[oldest] = nil
        }
    }

    /// Reads the package, starts and verifies the child, and only then
    /// attests: the engine serves only with the model its sessions name.
    func bootstrap(packageRoot: String, childDir: String, decoy: String, maxContext: Int, kvBudgetBytes: UInt64, _ done: @escaping (Error?) -> Void) {
        guard service.isSupported else { return done(EngineError.unsupported) }
        DispatchQueue.global().async {
            do {
                guard !packageRoot.isEmpty, !childDir.isEmpty, !decoy.isEmpty else { throw EngineError.config }
                let pkg = try ModelPackage(root: packageRoot)
                log("package: manifest \(pkg.manifestHash.hex) tokenizer \(pkg.tokenizerHash.hex) model \(pkg.modelHash.hex)")
                let be = try SplashBackend(childPath: "\(childDir)/splash", decoyPath: decoy, package: pkg,
                                           maxContext: maxContext, kvBudgetBytes: kvBudgetBytes, logFD: logFD)
                log("child ready: pid \(be.pid) context \(be.maxContext)")
                self.queue.sync {
                    self.package = pkg
                    self.backend = be
                    self.weightsHash = pkg.modelHash
                }
                self.attestKey(done)
            } catch {
                done(error)
            }
        }
    }

    private func attestKey(_ done: @escaping (Error?) -> Void) {
        service.generateKey { keyId, error in
            guard let keyId, error == nil else { return done(error ?? EngineError.keygen) }
            var nonce = Data(count: 32)
            _ = nonce.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
            let clientData = Data("sealed-engine/attest/v1".utf8) + nonce
            self.service.attestKey(keyId, clientDataHash: Data(SHA256.hash(data: clientData))) { att, error in
                guard let att, error == nil else { return done(error ?? EngineError.attest) }
                self.queue.sync {
                    self.keyId = keyId
                    self.attestation = att
                    self.attestClientData = clientData
                }
                done(nil)
            }
        }
    }

    func handle(_ req: HTTPRequest, respond: @escaping (Int, [String: Any]) -> Void) {
        // Every answer that carries an attestation, an assertion or a reply
        // needs a live, pinned child (incident 2026-10-21: the child was dead
        // for 11 h and /attest still answered 200).
        if ["/attest", "/session", "/probe", "/infer"].contains(req.path) {
            guard childAlive(respond) else { return }
        }
        switch (req.method, req.path) {
        case ("GET", "/attest"):
            queue.sync {
                guard !faulted else { return respond(503, ["error": "backend fault"]) }
                respond(200, ["keyId": keyId, "attestation": attestation.base64EncodedString(),
                              "clientData": attestClientData.base64EncodedString()])
            }
        case ("POST", "/session"):
            guard let body = try? JSONSerialization.jsonObject(with: req.body) as? [String: Any],
                  let challenge = (body["challenge"] as? String).flatMap({ Data(base64Encoded: $0) }), challenge.count == 32,
                  let clientPub = (body["clientPub"] as? String).flatMap({ Data(base64Encoded: $0) }), clientPub.count == 32
            else { return respond(400, ["error": "challenge and clientPub must be 32 bytes, base64"]) }
            let session = Curve25519.KeyAgreement.PrivateKey()
            guard let keys = try? EnvelopeKeys(enginePriv: session, clientPub: clientPub, challenge: challenge) else {
                return respond(400, ["error": "invalid client key"])
            }
            let sessionId = UUID().uuidString
            // clientData = challenge ‖ client X25519 ‖ engine X25519 ‖ model hash (128 bytes, v1 layout).
            let clientData = challenge + clientPub + session.publicKey.rawRepresentation + queue.sync { weightsHash }
            let keyId = queue.sync { self.keyId }
            service.generateAssertion(keyId, clientDataHash: Data(SHA256.hash(data: clientData))) { assertion, error in
                guard let assertion, error == nil else { return respond(503, ["error": "assertion refused"]) }
                // devicecheckd can take a while: check the child again before the assertion goes out.
                guard self.childAlive(respond) else { return }
                self.queue.sync {
                    self.evictSessions()
                    self.sessions[sessionId] = Session(keys: keys)
                }
                respond(200, ["sessionId": sessionId, "clientData": clientData.base64EncodedString(),
                              "assertion": assertion.base64EncodedString()])
            }
        case ("POST", "/probe"):
            guard let body = try? JSONSerialization.jsonObject(with: req.body) as? [String: Any],
                  let challenge = (body["challenge"] as? String).flatMap({ Data(base64Encoded: $0) }), challenge.count == 32
            else { return respond(400, ["error": "challenge must be 32 bytes, base64"]) }
            let clientData = challenge + providerTag + Data(count: 32) + queue.sync { weightsHash }
            let keyId = queue.sync { self.keyId }
            service.generateAssertion(keyId, clientDataHash: Data(SHA256.hash(data: clientData))) { assertion, error in
                guard let assertion, error == nil else { return respond(503, ["error": "assertion refused"]) }
                guard self.childAlive(respond) else { return }
                respond(200, ["clientData": clientData.base64EncodedString(), "assertion": assertion.base64EncodedString()])
            }
        case ("POST", "/infer"):
            queue.sync { self.infer(req.body, respond: respond) }
        default:
            respond(404, ["error": "not found"])
        }
    }

    private var faulted = false

    /// sealed_bringup_alive before an answer (a few non-blocking syscalls, no
    /// lock shared with a generation). On a dead or changed child the engine
    /// fails closed, as on the chat path: it logs "backend fault; stopping",
    /// answers this and every later request with 503 (no attestation), and
    /// exits with status 6. false = already answered.
    private func childAlive(_ respond: @escaping (Int, [String: Any]) -> Void) -> Bool {
        let (be, wasFaulted) = queue.sync { (backend, faulted) }
        var why = "engine stopped on a backend fault"
        if !wasFaulted {
            guard let be else { respond(503, ["error": "not ready"]); return false }
            do { try be.checkAlive(); return true } catch BackendError.dead(let w) { why = w } catch { why = "\(error)" }
        }
        let first = queue.sync { () -> Bool in
            defer { faulted = true }
            return !faulted
        }
        respond(503, ["error": "backend fault"])
        if first {
            log("backend fault; stopping (\(why))")
            // Give the 503 time to reach the client; `faulted` already refuses everything else.
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { exit(6) }
        }
        return false
    }

    /// Must be called on `queue`.
    private func infer(_ body: Data, respond: @escaping (Int, [String: Any]) -> Void) {
        guard let frame = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let sid = frame["sessionId"] as? String,
              let seq = strictUInt64(frame["seq"]),
              let ct = (frame["ct"] as? String).flatMap({ Data(base64Encoded: $0) })
        else { return respond(400, ["error": "malformed frame"]) }
        guard let session = sessions[sid] else { return respond(404, ["error": "unknown session"]) }
        guard let backend, let package else { return respond(503, ["error": "not ready"]) }
        if session.generating { return respond(409, ["error": "busy"]) }
        do {
            guard seq == session.recvSeq else { throw EnvelopeError.sequence }
            let plaintext = try session.keys.open(ct, seq: session.recvSeq)
            session.recvSeq += 1
            let request = try ChatRequest(json: plaintext)
            session.generating = true
            DispatchQueue.global().async {
                var reply: (Int, [String: Any])
                do {
                    var ctx: [String: any Sendable] = [:]
                    if let t = request.enableThinking { ctx["enable_thinking"] = t }
                    let prompt = try package.tokenizer.applyChatTemplate(
                        messages: request.messages, chatTemplate: .literal(package.chatTemplate),
                        addGenerationPrompt: true, truncation: false, maxLength: nil, tools: nil,
                        additionalContext: ctx.isEmpty ? nil : ctx)
                    let c = try backend.generate(prompt: prompt, maxTokens: request.maxTokens, temperature: request.temperature)
                    let text = package.tokenizer.decode(tokens: c.tokens, skipSpecialTokens: true)
                    reply = self.queue.sync { () -> (Int, [String: Any]) in
                        guard let frames = try? self.sealFrames(session, sid: sid, chunks: Self.chunks(text)) else { return (500, ["error": "sealing failed"]) }
                        return (200, ["frames": frames])
                    }
                } catch BackendError.identity, BackendError.channel, BackendError.protocolFault {
                    // The child is no longer the verified one or the channel broke:
                    // fail closed for the whole engine.
                    log("backend fault; stopping")
                    exit(6)
                } catch BackendError.refused(let why) {
                    // The child's text carries a number derived from the
                    // prompt length (audits E-01, R2-E-01). The engine log is
                    // readable by the provider, so neither the reply nor the
                    // log carries it.
                    _ = why
                    log("request refused")
                    reply = (503, ["error": "refused"])
                } catch {
                    reply = (500, ["error": "inference failed"])
                }
                self.queue.sync { session.generating = false }
                respond(reply.0, reply.1)
            }
        } catch {
            respond(422, ["error": "rejected"])
        }
    }

    private static func chunks(_ s: String) -> [String] {
        if s.isEmpty { return [""] }
        var out: [String] = []
        var cur = ""
        // A chunk holds at most 1024 UTF-8 bytes (the padded frame body).
        // Cut between Unicode scalars (at most 4 bytes each), never between
        // grapheme clusters: one grapheme can exceed 1024 bytes (audit R2-E-03).
        var bytes = 0
        for u in s.unicodeScalars {
            let n = String(u).utf8.count
            if bytes + n > 1024 { out.append(cur); cur = ""; bytes = 0 }
            cur.unicodeScalars.append(u)
            bytes += n
        }
        if !cur.isEmpty { out.append(cur) }
        return out
    }

    /// Padded frame plaintext: flag | u16 data length | data | zero padding,
    /// always `Self.padBody` bytes after the flag. Flags: 0x02 = more,
    /// 0x03 = final. The frame count is rounded up to a power of two with
    /// empty frames, so an observer of the ciphertext learns only the
    /// power-of-two size class of the reply length, not its value.
    static let padBody = 1026          // 2-byte length + 1024 data bytes
    static let flagPadMore: UInt8 = 0x02
    static let flagPadFinal: UInt8 = 0x03

    /// Seals chunks as one padded response. Must be called on `queue`.
    private func sealFrames(_ session: Session, sid: String, chunks: [String]) throws -> [[String: Any]] {
        var bodies: [Data] = chunks.map { Data($0.utf8) }
        var n = 1
        while n < bodies.count { n <<= 1 }
        while bodies.count < n { bodies.append(Data()) }
        var frames: [[String: Any]] = []
        for (i, body) in bodies.enumerated() {
            guard body.count <= Self.padBody - 2 else { throw EnvelopeError.open }
            let flag: UInt8 = i == bodies.count - 1 ? Self.flagPadFinal : Self.flagPadMore
            var pt = Data([flag, UInt8(body.count >> 8), UInt8(body.count & 0xff)])
            pt.append(body)
            pt.append(Data(count: Self.padBody - 2 - body.count))
            let seq = session.sendSeq
            let sealed = try session.keys.seal(pt, seq: seq)
            session.sendSeq += 1
            frames.append(["sessionId": sid, "seq": seq, "ct": sealed.base64EncodedString()])
        }
        return frames
    }
}

enum EngineError: Error { case unsupported, keygen, attest, config }

/// The decrypted OpenAI-style chat request.
struct ChatRequest {
    let messages: [[String: any Sendable]]
    let maxTokens: Int
    let temperature: Float
    let enableThinking: Bool?

    init(json: Data) throws {
        guard let obj = try JSONSerialization.jsonObject(with: json) as? [String: Any],
              let raw = obj["messages"] as? [[String: Any]], !raw.isEmpty
        else { throw EnvelopeError.open }
        var msgs: [[String: any Sendable]] = []
        for m in raw {
            guard let content = m["content"] as? String, let role = m["role"] as? String,
                  ["system", "user", "assistant"].contains(role) else { throw EnvelopeError.open }
            msgs.append(["role": role, "content": content])
        }
        guard (msgs.last?["role"] as? String) == "user" else { throw EnvelopeError.open }
        messages = msgs
        maxTokens = min(max((obj["max_tokens"] as? Int) ?? 256, 1), 4096)
        let t = (obj["temperature"] as? Double) ?? 0.6
        temperature = Float(t.isFinite ? min(max(t, 0), 2) : 0.6)
        enableThinking = obj["enable_thinking"] as? Bool
    }
}

private func strictUInt64(_ v: Any?) -> UInt64? {
    guard let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
    let d = n.doubleValue
    guard d >= 0, d.rounded() == d, d < 1.8446744073709552e19 else { return nil }
    return n.uint64Value
}
