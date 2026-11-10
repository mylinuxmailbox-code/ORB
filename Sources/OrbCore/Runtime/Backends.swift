import Foundation

/// An inference engine ORB can configure, run and probe.
public protocol InferenceBackend: Sendable {
    var id: BackendID { get }
    /// Bind the backend to a model. `modelDirectory` is the local directory for HF-downloaded models.
    func configure(model: CatalogModel, modelDirectory: URL) async throws
    func start() async throws
    func stop() async
    func healthCheck() async -> Bool
}

// MARK: - Ollama

public actor OllamaBackend: InferenceBackend {
    public nonisolated let id: BackendID = .ollama
    private let pm: ProcessManager
    private let binary: URL
    public private(set) var modelTag: String = ""
    private var startedByUs = false
    static let serviceName = "ollama"

    public init(binary: URL, processManager: ProcessManager = .shared) { self.binary = binary; self.pm = processManager }

    public func configure(model: CatalogModel, modelDirectory: URL) async throws {
        guard !model.repoID.isEmpty else { throw OrbError.message("LLM model has no Ollama tag.") }
        modelTag = model.repoID
    }

    public func healthCheck() async -> Bool { await HTTP.isUp(Endpoints.ollama.appendingPathComponent("api/version")) }

    public func start() async throws {
        if await healthCheck() { return }   // already running (Ollama.app, brew service, …)
        try await pm.start(ServiceSpec(name: Self.serviceName, executable: binary.path, arguments: ["serve"],
                                       environment: ["OLLAMA_HOST": "127.0.0.1:11434"]))
        startedByUs = true
        try await pm.waitHealthy(Self.serviceName, url: Endpoints.ollama.appendingPathComponent("api/version"), timeout: 45)
    }

    public func stop() async { if startedByUs { await pm.stop(Self.serviceName); startedByUs = false } }

    public func installedModels() async throws -> [String] {
        let (d, code) = try await HTTP.send(Endpoints.ollama.appendingPathComponent("api/tags"), timeout: 10)
        guard code == 200, let j = try JSONSerialization.jsonObject(with: d) as? [String: Any] else { throw OrbError.message("Ollama /api/tags returned HTTP \(code)") }
        return ((j["models"] as? [[String: Any]]) ?? []).compactMap { $0["name"] as? String }
    }

    public static func tagMatches(_ installed: String, _ wanted: String) -> Bool {
        installed == wanted || installed == wanted + ":latest" || (!wanted.contains(":") && installed.hasPrefix(wanted + ":latest"))
    }

    public func hasModel(_ tag: String? = nil) async -> Bool {
        let t = tag ?? modelTag
        return ((try? await installedModels()) ?? []).contains { Self.tagMatches($0, t) }
    }

    /// POST /api/pull streaming progress.
    public func pull(progress: @escaping @Sendable (DownloadProgress) -> Void) async throws {
        let tag = modelTag
        var req = URLRequest(url: Endpoints.ollama.appendingPathComponent("api/pull"))
        req.httpMethod = "POST"; req.timeoutInterval = 900
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["model": tag, "stream": true])
        let (bytes, resp) = try await HTTP.session.bytes(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            var body = ""; for try await l in bytes.lines { body += l }
            throw OrbError.message("ollama pull \(tag) failed: \(body)")
        }
        let start = Date(); var lastDigest = ""; var digestStart = Date()
        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard let j = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
            if let err = j["error"] as? String { throw OrbError.message("ollama pull \(tag) failed: \(err)") }
            let status = (j["status"] as? String) ?? ""
            let total = (j["total"] as? NSNumber)?.int64Value ?? 0
            let done = (j["completed"] as? NSNumber)?.int64Value ?? 0
            let digest = (j["digest"] as? String) ?? status
            if digest != lastDigest { lastDigest = digest; digestStart = Date() }
            let el = max(Date().timeIntervalSince(digestStart), 0.001)
            let bps = total > 0 ? Double(done) / el : 0
            _ = start
            let label = total > 0 ? tag : (status.isEmpty ? tag : "\(tag) (\(status))")
            progress(DownloadProgress(fileName: label, bytesDone: done, bytesTotal: total, bytesPerSecond: bps,
                                      etaSeconds: bps > 1 && total > done ? Double(total - done) / bps : nil))
        }
        guard await hasModel(tag) else { throw OrbError.message("ollama pull finished but model \(tag) is not listed by Ollama.") }
    }

    /// Non-streaming chat used for verification. Returns the assistant text.
    public func quickChat(_ prompt: String, maxTokens: Int = 128) async throws -> String {
        func attempt(think: Bool?) async throws -> String {
            var body: [String: Any] = ["model": modelTag, "stream": false,
                                       "messages": [["role": "user", "content": prompt]],
                                       "options": ["num_predict": maxTokens, "temperature": 0.2]]
            if let think { body["think"] = think }
            let (d, code) = try await HTTP.send(Endpoints.ollama.appendingPathComponent("api/chat"), method: "POST",
                                                body: try JSONSerialization.data(withJSONObject: body),
                                                headers: ["Content-Type": "application/json"], timeout: 180)
            let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any]
            guard code == 200 else { throw OrbError.message("Ollama chat HTTP \(code): \((j?["error"] as? String) ?? String(decoding: d, as: UTF8.self))") }
            return (((j?["message"] as? [String: Any])?["content"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let first = try await attempt(think: nil)
        if !first.isEmpty { return first }
        return (try? await attempt(think: false)) ?? ""
    }
}

// MARK: - whisper.cpp

public actor WhisperCppBackend: InferenceBackend {
    public nonisolated let id: BackendID = .whispercpp
    private let pm: ProcessManager
    private let binary: URL
    private var modelPath: URL?
    static let serviceName = "whisper"

    public init(binary: URL, processManager: ProcessManager = .shared) { self.binary = binary; self.pm = processManager }

    public func configure(model: CatalogModel, modelDirectory: URL) async throws {
        let candidates = model.files.map { f in
            f.path.hasPrefix("/") ? URL(fileURLWithPath: f.path) : modelDirectory.appendingPathComponent(f.path)
        }
        guard let bin = candidates.first(where: { $0.pathExtension == "bin" && FileManager.default.fileExists(atPath: $0.path) }) else {
            throw OrbError.message("Whisper model file (*.bin) for \(model.name) not found in \(modelDirectory.path). Re-run the download step.")
        }
        modelPath = bin
    }
    public func healthCheck() async -> Bool { await HTTP.isUp(Endpoints.whisper) }
    public func start() async throws {
        guard let modelPath else { throw OrbError.message("WhisperCppBackend not configured.") }
        if await healthCheck() { return }
        try await pm.start(ServiceSpec(name: Self.serviceName, executable: binary.path,
                                       arguments: ["-m", modelPath.path, "--port", "18181", "--host", "127.0.0.1"]))
        try await pm.waitHealthy(Self.serviceName, url: Endpoints.whisper, timeout: 90)
    }
    public func stop() async { await pm.stop(Self.serviceName) }

    /// Transcribe a WAV (any rate/channels; converted to 16 kHz mono PCM16 as whisper-server requires).
    public func transcribe(wav: Data, language: String? = nil) async throws -> String {
        let pcm = try WAV.to16kMono(wav)
        let boundary = "orb-" + UUID().uuidString
        var body = Data()
        func field(_ n: String, _ v: String) { body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(n)\"\r\n\r\n\(v)\r\n".utf8)) }
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\nContent-Type: audio/wav\r\n\r\n".utf8))
        body.append(pcm); body.append(Data("\r\n".utf8))
        field("response_format", "json"); field("temperature", "0.0")
        if let language { field("language", language) }
        body.append(Data("--\(boundary)--\r\n".utf8))
        let (d, code) = try await HTTP.send(Endpoints.whisper.appendingPathComponent("inference"), method: "POST", body: body,
                                            headers: ["Content-Type": "multipart/form-data; boundary=\(boundary)"], timeout: 120)
        guard code == 200, let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else {
            throw OrbError.message("whisper-server /inference HTTP \(code): \(String(decoding: d.prefix(300), as: UTF8.self))")
        }
        return ((j["text"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Piper

public actor PiperBackend: InferenceBackend {
    public nonisolated let id: BackendID = .piper
    private let pm: ProcessManager
    private let python: URL
    private var modelPath: URL?
    static let serviceName = "piper"
    public static var scriptURL: URL { Paths.runtimes.appendingPathComponent("tts_server.py") }

    public init(python: URL, processManager: ProcessManager = .shared) { self.python = python; self.pm = processManager }

    public func configure(model: CatalogModel, modelDirectory: URL) async throws {
        let cands = model.files.map { f in
            f.path.hasPrefix("/") ? URL(fileURLWithPath: f.path) : modelDirectory.appendingPathComponent(f.path)
        }
        guard let onnx = cands.first(where: { $0.pathExtension == "onnx" && FileManager.default.fileExists(atPath: $0.path) }) else {
            throw OrbError.message("Piper voice (*.onnx) for \(model.name) not found in \(modelDirectory.path). Re-run the download step.")
        }
        let cfg = cands.first(where: { $0.path.hasSuffix(".onnx.json") && FileManager.default.fileExists(atPath: $0.path) })
            ?? URL(fileURLWithPath: onnx.path + ".json")
        guard FileManager.default.fileExists(atPath: cfg.path) else {
            throw OrbError.message("Piper voice config \(cfg.lastPathComponent) is missing next to the .onnx file.")
        }
        modelPath = onnx
        try Paths.ensureAll()
        try Self.serverScript.write(to: Self.scriptURL, atomically: true, encoding: .utf8)
    }
    public func healthCheck() async -> Bool {
        let (d, code) = (try? await HTTP.send(Endpoints.tts.appendingPathComponent("health"), timeout: 2)) ?? (Data(), 0)
        _ = d; return code == 200
    }
    public func start() async throws {
        guard let modelPath else { throw OrbError.message("PiperBackend not configured.") }
        if await healthCheck() { return }
        try await pm.start(ServiceSpec(name: Self.serviceName, executable: python.path,
                                       arguments: [Self.scriptURL.path, "--model", modelPath.path, "--config", modelPath.path + ".json",
                                                   "--port", "18182", "--host", "127.0.0.1"],
                                       environment: ["PYTHONUNBUFFERED": "1"]))
        try await pm.waitHealthy(Self.serviceName, url: Endpoints.tts.appendingPathComponent("health"), timeout: 90)
    }
    public func stop() async { await pm.stop(Self.serviceName) }

    public func synthesize(_ text: String) async throws -> Data {
        let body = try JSONSerialization.data(withJSONObject: ["text": text])
        let (d, code) = try await HTTP.send(Endpoints.tts.appendingPathComponent("tts"), method: "POST", body: body,
                                            headers: ["Content-Type": "application/json"], timeout: 120)
        guard code == 200 else { throw OrbError.message("Piper /tts HTTP \(code): \(String(decoding: d.prefix(300), as: UTF8.self))") }
        return d
    }

    static let serverScript = #"""
    #!/usr/bin/env python3
    # ORB Piper TTS server (generated). GET /health, POST /tts {"text": "..."} -> audio/wav
    import argparse, asyncio, io, wave
    from aiohttp import web
    from piper import PiperVoice

    ap = argparse.ArgumentParser()
    ap.add_argument("--model", required=True)
    ap.add_argument("--config", default=None)
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=18182)
    args = ap.parse_args()

    voice = PiperVoice.load(args.model, config_path=args.config)   # loaded once
    lock = asyncio.Lock()

    def synth(text):
        buf = io.BytesIO()
        with wave.open(buf, "wb") as w:
            if hasattr(voice, "synthesize_wav"):     # piper-tts >= 1.3
                voice.synthesize_wav(text, w)
            else:                                    # piper-tts 1.2
                voice.synthesize(text, w)
        return buf.getvalue()

    async def health(_):
        return web.json_response({"status": "ok"})

    async def tts(request):
        try:
            data = await request.json()
            text = (data.get("text") or "").strip()
        except Exception:
            return web.json_response({"error": "expected JSON {\"text\": ...}"}, status=400)
        if not text:
            return web.json_response({"error": "empty text"}, status=400)
        async with lock:
            try:
                wav = await asyncio.get_running_loop().run_in_executor(None, synth, text)
            except Exception as e:
                return web.json_response({"error": str(e)}, status=500)
        return web.Response(body=wav, content_type="audio/wav")

    app = web.Application()
    app.add_routes([web.get("/health", health), web.post("/tts", tts)])
    web.run_app(app, host=args.host, port=args.port, print=lambda *_: None)
    """#
}

// MARK: - WAV utilities

extension WAV {
    /// Parse PCM16 WAV and return (sampleRate, channels, samples interleaved).
    public static func parse(_ d: Data) throws -> (rate: Int, channels: Int, samples: [Int16]) {
        let b = [UInt8](d)
        func u32(_ i: Int) -> Int { Int(b[i]) | Int(b[i+1]) << 8 | Int(b[i+2]) << 16 | Int(b[i+3]) << 24 }
        func u16(_ i: Int) -> Int { Int(b[i]) | Int(b[i+1]) << 8 }
        guard b.count > 44, String(decoding: b[0..<4], as: UTF8.self) == "RIFF", String(decoding: b[8..<12], as: UTF8.self) == "WAVE" else {
            throw OrbError.message("Not a WAV file")
        }
        var i = 12; var rate = 0, ch = 0, bits = 0, fmtTag = 0
        while i + 8 <= b.count {
            let id = String(decoding: b[i..<i+4], as: UTF8.self); var size = u32(i + 4)
            if id == "fmt " { fmtTag = u16(i + 8); ch = u16(i + 10); rate = u32(i + 12); bits = u16(i + 22) }
            if id == "data" {
                guard fmtTag == 1 || fmtTag == 0xFFFE, bits == 16, ch > 0, rate > 0 else { throw OrbError.message("Unsupported WAV format (need PCM16)") }
                size = min(size, b.count - i - 8)
                let n = size / 2
                var s = [Int16](repeating: 0, count: n)
                for k in 0..<n { s[k] = Int16(bitPattern: UInt16(b[i+8+2*k]) | UInt16(b[i+9+2*k]) << 8) }
                return (rate, ch, s)
            }
            i += 8 + size + (size & 1)
        }
        throw OrbError.message("WAV has no data chunk")
    }

    public static func encode(samples: [Int16], rate: Int, channels: Int = 1) -> Data {
        var d = Data()
        func p32(_ v: Int) { var x = UInt32(v).littleEndian; d.append(Data(bytes: &x, count: 4)) }
        func p16(_ v: Int) { var x = UInt16(v).littleEndian; d.append(Data(bytes: &x, count: 2)) }
        d.append(Data("RIFF".utf8)); p32(36 + samples.count * 2); d.append(Data("WAVEfmt ".utf8))
        p32(16); p16(1); p16(channels); p32(rate); p32(rate * channels * 2); p16(channels * 2); p16(16)
        d.append(Data("data".utf8)); p32(samples.count * 2)
        samples.withUnsafeBufferPointer { d.append(Data(buffer: $0)) }   // little-endian host
        return d
    }

    public static func duration(_ d: Data) -> Double? {
        guard let p = try? parse(d) else { return nil }
        return Double(p.samples.count / p.channels) / Double(p.rate)
    }

    /// Downmix to mono and linearly resample to 16 kHz PCM16 WAV.
    public static func to16kMono(_ d: Data) throws -> Data {
        let p = try parse(d)
        let frames = p.samples.count / p.channels
        var mono = [Float](repeating: 0, count: frames)
        for f in 0..<frames {
            var s: Float = 0
            for c in 0..<p.channels { s += Float(p.samples[f * p.channels + c]) }
            mono[f] = s / Float(p.channels)
        }
        let target = 16000
        if p.rate == target && p.channels == 1 { return d }
        let outN = Int(Double(frames) * Double(target) / Double(p.rate))
        var out = [Int16](repeating: 0, count: outN)
        let ratio = Double(p.rate) / Double(target)
        for k in 0..<outN {
            let pos = Double(k) * ratio; let i0 = Int(pos); let fr = Float(pos - Double(i0))
            let a = mono[min(i0, frames - 1)], b = mono[min(i0 + 1, frames - 1)]
            out[k] = Int16(max(-32768, min(32767, a + (b - a) * fr)))
        }
        return encode(samples: out, rate: target)
    }
}
