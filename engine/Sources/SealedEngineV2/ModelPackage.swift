import CryptoKit
import Foundation
import Hub
import Tokenizers

/// The model package as the engine reads it: each file once, without
/// following symlinks, into memory; the hashes are taken over those bytes,
/// and the tokenizer is built from the same bytes (no second read).
struct ModelPackage {
    static let tokenizerFiles = ["tokenizer.json", "tokenizer_config.json", "chat_template.jinja", "config.json", "vocab.json"]

    let root: String
    let manifest: Data           // sealed-manifest.bin (file form)
    let manifestHash: Data       // hash form, backend kind 2 (Splash)
    let tokenizerHash: Data
    let modelHash: Data          // bound into every session and probe (the v1 "weights hash" slot)
    let tokenizer: PreTrainedTokenizer
    let chatTemplate: String

    init(root: String) throws {
        self.root = root
        manifest = try Self.readOnce("\(root)/sealed-manifest.bin", limit: 1 << 20)
        guard manifest.count >= 22, manifest.prefix(18) == Data("sealed-manifest-v2".utf8) else { throw PackageError.manifest }
        manifestHash = Data(SHA256.hash(data: manifest.prefix(18) + Data([0, 0, 0, 2]) + manifest.dropFirst(18)))
        var files: [String: Data] = [:]
        var h = SHA256()
        for name in Self.tokenizerFiles {
            let bytes = try Self.readOnce("\(root)/tokenizer/\(name)", limit: 64 << 20)
            files[name] = bytes
            h.update(data: Data(name.utf8) + Data([0]))
            var n = UInt64(bytes.count).bigEndian
            h.update(data: Data(bytes: &n, count: 8))
            h.update(data: bytes)
        }
        tokenizerHash = Data(h.finalize())
        modelHash = Data(SHA256.hash(data: Data("morpheus-sealed/v2/splash-model".utf8) + manifestHash + tokenizerHash + Data(ChildPin.cdhash)))
        func json(_ name: String) throws -> Config {
            guard let d = try JSONSerialization.jsonObject(with: files[name]!) as? [NSString: Any] else { throw PackageError.tokenizer(name) }
            return Config(d)
        }
        guard let template = String(data: files["chat_template.jinja"]!, encoding: .utf8) else { throw PackageError.tokenizer("chat_template.jinja") }
        chatTemplate = template
        var cfg = try json("tokenizer_config.json").dictionary() ?? [:]
        cfg["chat_template"] = .init(template)
        tokenizer = try PreTrainedTokenizer(tokenizerConfig: Config(cfg), tokenizerData: try json("tokenizer.json"))
    }

    /// One open with O_NOFOLLOW, a regular file, a size cap, one read.
    static func readOnce(_ path: String, limit: Int) throws -> Data {
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw PackageError.open(path) }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, st.st_size > 0, st.st_size <= limit else { throw PackageError.open(path) }
        var data = Data(count: Int(st.st_size))
        let got = data.withUnsafeMutableBytes { buf -> Int in
            var off = 0
            while off < buf.count {
                let r = read(fd, buf.baseAddress! + off, buf.count - off)
                if r <= 0 { return off }
                off += r
            }
            return off
        }
        guard got == Int(st.st_size) else { throw PackageError.open(path) }
        return data
    }
}

enum PackageError: Error { case manifest, open(String), tokenizer(String) }

extension Data {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}
