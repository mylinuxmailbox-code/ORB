import Foundation
import Combine
import AVFoundation
import CoreAudio

struct StepFailure: Error { let message: String }

@MainActor
public final class SetupEngine: ObservableObject {
    @Published public private(set) var steps: [SetupStep] = SetupStepID.allCases.map { SetupStep(id: $0, title: SetupEngine.title($0)) }
    @Published public private(set) var orbState: OrbState = .idle
    @Published public private(set) var currentOperation: String = ""
    /// Overall progress 0...1.
    @Published public private(set) var progress: Double = 0
    @Published public private(set) var downloadProgress: DownloadProgress?
    @Published public private(set) var logs: [String] = []
    @Published public private(set) var error: String?
    @Published public private(set) var isRunning = false

    private let hardware: HardwareDetecting
    private let downloader: ModelDownloading
    private let pm: ProcessManager
    private var task: Task<Void, Never>?
    private var logTask: Task<Void, Never>?

    private var hw: HardwareProfile?
    private var ollama: OllamaBackend?
    private var whisper: WhisperCppBackend?
    private var piper: PiperBackend?

    public init(hardware: HardwareDetecting, downloader: ModelDownloading, processManager: ProcessManager = .shared) {
        self.hardware = hardware; self.downloader = downloader; self.pm = processManager
    }

    nonisolated static func title(_ id: SetupStepID) -> String {
        switch id {
        case .detectHardware: return "Detect hardware"
        case .validateModels: return "Validate model selection"
        case .checkDisk: return "Check disk space"
        case .installRuntimes: return "Install runtimes"
        case .createEnvironment: return "Create Python environment"
        case .downloadModels: return "Download models"
        case .verifyDownloads: return "Verify downloads"
        case .configureBackends: return "Configure backends"
        case .configureAudio: return "Check audio devices"
        case .startServices: return "Start services"
        case .connectPipeline: return "Connect pipeline"
        case .endToEndTest: return "End-to-end test"
        case .markReady: return "Mark ready"
        }
    }

    // MARK: Config persistence
    public nonisolated static func loadConfig() -> OrbConfig? {
        guard let d = try? Data(contentsOf: Paths.config) else { return nil }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        return try? dec.decode(OrbConfig.self, from: d)
    }
    public nonisolated static func saveConfig(_ c: OrbConfig) throws {
        try Paths.ensureAll()
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(c).write(to: Paths.config, options: .atomic)
    }

    // MARK: Logging helpers
    func appendLog(_ s: String) {
        logs.append(s); if logs.count > 3000 { logs.removeFirst(500) }
    }
    private var installer: RuntimeInstaller {
        RuntimeInstaller(log: { [weak self] l in Task { @MainActor in self?.appendLog(l); self?.currentOperation = l.count > 120 ? String(l.prefix(120)) : l } })
    }
    private func setStep(_ id: SetupStepID, _ status: StepStatus, _ detail: String = "") {
        guard let i = steps.firstIndex(where: { $0.id == id }) else { return }
        steps[i].status = status; steps[i].detail = detail
    }

    // MARK: Control
    public func cancel() {
        guard isRunning else { return }
        appendLog("Cancelling…")
        task?.cancel()
    }

    /// Runs all setup steps. Safe to call again: completed work is detected and skipped (resume).
    public func run(config: OrbConfig) async {
        guard !isRunning else { return }
        isRunning = true; error = nil; progress = 0; downloadProgress = nil
        for id in SetupStepID.allCases { setStep(id, .pending) }
        orbState = .initializing
        let t = Task { await self.execute(config) }
        task = t
        await t.value
        task = nil; isRunning = false
    }

    private func execute(_ config: OrbConfig) async {
        // forward service logs
        logTask?.cancel()
        let stream = await pm.logStream()
        logTask = Task { [weak self] in for await l in stream { await MainActor.run { self?.appendLog(l) } } }
        defer { logTask?.cancel() }

        let all = SetupStepID.allCases
        for (n, id) in all.enumerated() {
            setStep(id, .running, "")
            currentOperation = Self.title(id)
            progress = Double(n) / Double(all.count)
            do {
                try Task.checkCancellation()
                let detail = try await perform(id, config)
                setStep(id, .done, detail)
            } catch {
                if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled {
                    setStep(id, .pending, "Cancelled")
                    currentOperation = "Cancelled"; orbState = .idle; downloadProgress = nil
                    appendLog("Setup cancelled at “\(Self.title(id))”. Run again to resume.")
                    await stopServices()
                    return
                }
                let msg = (error as? StepFailure)?.message ?? (error as? OrbError)?.errorDescription ?? error.localizedDescription
                setStep(id, .failed, msg)
                self.error = "\(Self.title(id)) failed: \(msg)"
                orbState = .error; currentOperation = "Failed: \(Self.title(id))"
                appendLog("✗ \(Self.title(id)): \(msg)")
                return
            }
        }
        progress = 1; orbState = .ready; currentOperation = "ORB is ready"; downloadProgress = nil
    }

    private func perform(_ id: SetupStepID, _ cfg: OrbConfig) async throws -> String {
        switch id {
        case .detectHardware:
            let p = await hardware.detect(); hw = p
            return "\(p.chip), \(Int(p.memoryGB)) GB RAM, \(Int(p.freeDiskGB)) GB free"

        case .validateModels:
            var problems: [String] = []
            if cfg.llm.backend != .ollama || cfg.llm.kind != .llm { problems.append("LLM must use the Ollama backend") }
            if cfg.stt.backend != .whispercpp || cfg.stt.kind != .stt { problems.append("STT must use whisper.cpp") }
            if cfg.tts.backend != .piper || cfg.tts.kind != .tts { problems.append("TTS must use Piper") }
            if cfg.llm.repoID.isEmpty { problems.append("LLM has no Ollama tag") }
            if !cfg.stt.files.contains(where: { $0.path.hasSuffix(".bin") }) { problems.append("STT model lists no ggml .bin file") }
            if !cfg.tts.files.contains(where: { $0.path.hasSuffix(".onnx") }) { problems.append("TTS voice lists no .onnx file") }
            if !cfg.tts.files.contains(where: { $0.path.hasSuffix(".onnx.json") }) { problems.append("TTS voice lists no .onnx.json config") }
            if let hw, cfg.llm.minMemoryGB > hw.memoryGB { problems.append("\(cfg.llm.name) needs ≥\(cfg.llm.minMemoryGB) GB RAM; this Mac has \(Int(hw.memoryGB)) GB") }
            if !problems.isEmpty { throw StepFailure(message: problems.joined(separator: "; ") + ". Choose compatible models and retry.") }
            return "Models compatible"

        case .checkDisk:
            var need: Int64 = 1_500_000_000   // runtimes + venv margin
            for m in [cfg.stt, cfg.tts] where !downloader.isDownloaded(m) { need += m.sizeBytes }
            if let o = ollama ?? ollamaIfPresent(), await o.hasModel(cfg.llm.repoID) { } else { need += cfg.llm.sizeBytes }
            try Paths.ensureAll()
            let free = Self.freeBytes(Paths.models) ?? Int64((hw?.freeDiskGB ?? 0) * 1e9)
            let gb = { (b: Int64) in String(format: "%.1f", Double(b) / 1e9) }
            guard free >= need + 500_000_000 else {
                throw StepFailure(message: "Need about \(gb(need)) GB but only \(gb(free)) GB is free. Free up space or pick smaller models.")
            }
            return "\(gb(free)) GB free, ~\(gb(need)) GB needed"

        case .installRuntimes:
            orbState = .installing
            let inst = installer
            let o = try await inst.ensureOllama()
            let w = try await inst.ensureWhisper()
            _ = try await inst.ensurePython()
            ollama = OllamaBackend(binary: o, processManager: pm)
            whisper = WhisperCppBackend(binary: w, processManager: pm)
            return "Ollama, whisper-server, Python ready"

        case .createEnvironment:
            orbState = .installing
            let inst = installer
            let py = try await inst.ensureVenv()
            try await inst.ensurePiper()
            piper = PiperBackend(python: py, processManager: pm)
            return "piper-tts + aiohttp in \(Paths.venv.lastPathComponent)"

        case .downloadModels:
            orbState = .downloading
            for m in [cfg.stt, cfg.tts] {
                if downloader.isDownloaded(m) { appendLog("\(m.name) already downloaded"); continue }
                currentOperation = "Downloading \(m.name)"
                _ = try await downloader.download(m) { [weak self] p in Task { @MainActor in self?.downloadProgress = p } }
            }
            guard let o = ollama else { throw StepFailure(message: "Ollama backend missing (runtime step did not run).") }
            try await o.configure(model: cfg.llm, modelDirectory: Paths.models)
            try await o.start()
            if await o.hasModel(cfg.llm.repoID) { appendLog("\(cfg.llm.repoID) already pulled") }
            else {
                currentOperation = "Pulling \(cfg.llm.repoID)"
                try await o.pull { [weak self] p in Task { @MainActor in self?.downloadProgress = p } }
            }
            downloadProgress = nil; orbState = .initializing
            return "STT, TTS, and LLM downloaded"

        case .verifyDownloads:
            for m in [cfg.stt, cfg.tts] {
                guard downloader.isDownloaded(m) else { throw StepFailure(message: "\(m.name) is not fully downloaded. Re-run setup to resume.") }
                let dir = downloader.localDirectory(for: m)
                for f in m.files {
                    let u = f.path.hasPrefix("/") ? URL(fileURLWithPath: f.path) : dir.appendingPathComponent(f.path)
                    guard let attr = try? FileManager.default.attributesOfItem(atPath: u.path), let sz = (attr[.size] as? NSNumber)?.int64Value, sz > 0 else {
                        throw StepFailure(message: "Missing or empty file \(f.path) for \(m.name). Delete \(dir.path) and re-run setup.")
                    }
                    if let exp = f.sizeBytes, exp != sz { throw StepFailure(message: "\(f.path) is \(sz) bytes, expected \(exp). Delete it and re-run setup.") }
                }
            }
            guard let o = ollama, await o.hasModel(cfg.llm.repoID) else { throw StepFailure(message: "Ollama does not list \(cfg.llm.repoID). Run `ollama pull \(cfg.llm.repoID)`.") }
            return "All model files verified"

        case .configureBackends:
            try await prepareBackends(cfg)
            return "Backends configured"

        case .configureAudio:
            return try await checkAudio()

        case .startServices:
            try await startBackends()
            return "Ollama :11434, whisper :18181, Piper :18182 running"

        case .connectPipeline:
            guard let o = ollama else { throw StepFailure(message: "Backends not initialised.") }
            guard await o.hasModel(cfg.llm.repoID) else { throw StepFailure(message: "Ollama is up but model \(cfg.llm.repoID) is not available.") }
            for (n, u) in [("STT", Endpoints.whisper), ("TTS", Endpoints.tts.appendingPathComponent("health"))] {
                guard await HTTP.isUp(u) else { throw StepFailure(message: "\(n) service is not answering at \(u.absoluteString).") }
            }
            return "STT, LLM, TTS reachable"

        case .endToEndTest:
            return try await endToEnd(cfg)

        case .markReady:
            var c = cfg; c.setupCompleted = true; c.lastVerifiedAt = Date()
            // Only reached if every previous step passed.
            guard steps.filter({ $0.id != .markReady }).allSatisfy({ $0.status == .done }) else {
                throw StepFailure(message: "Not all checks passed.")
            }
            do { try Self.saveConfig(c) } catch { throw StepFailure(message: "Could not save config: \(error.localizedDescription)") }
            return "Configuration saved"
        }
    }

    private func ollamaIfPresent() -> OllamaBackend? {
        RuntimeInstaller().ollamaPath().map { OllamaBackend(binary: $0, processManager: pm) }
    }

    // MARK: Backends
    private func prepareBackends(_ cfg: OrbConfig) async throws {
        let inst = RuntimeInstaller()
        guard let o = inst.ollamaPath() else { throw StepFailure(message: "Ollama not found. Run setup to install it.") }
        guard let w = inst.whisperServerPath() else { throw StepFailure(message: "whisper-server not found. Run `brew install whisper-cpp`.") }
        guard FileManager.default.isExecutableFile(atPath: inst.venvPython.path), inst.piperImportable() else {
            throw StepFailure(message: "Piper environment missing. Re-run setup to recreate it.")
        }
        let ob = ollama ?? OllamaBackend(binary: o, processManager: pm)
        let wb = whisper ?? WhisperCppBackend(binary: w, processManager: pm)
        let pb = piper ?? PiperBackend(python: inst.venvPython, processManager: pm)
        try await ob.configure(model: cfg.llm, modelDirectory: Paths.models)
        try await wb.configure(model: cfg.stt, modelDirectory: downloader.localDirectory(for: cfg.stt))
        try await pb.configure(model: cfg.tts, modelDirectory: downloader.localDirectory(for: cfg.tts))
        ollama = ob; whisper = wb; piper = pb
    }

    private func startBackends() async throws {
        guard let o = ollama, let w = whisper, let p = piper else { throw StepFailure(message: "Backends are not configured.") }
        orbState = .initializing
        currentOperation = "Starting Ollama"; try await o.start()
        currentOperation = "Starting whisper-server"; try await w.start()
        currentOperation = "Starting Piper"; try await p.start()
    }

    /// Reusable by the app: configure and start Ollama, whisper-server and Piper (runtimes + models must already be installed).
    public func startServices(config: OrbConfig) async throws {
        do {
            try await prepareBackends(config)
            try await startBackends()
            guard let o = ollama, await o.hasModel(config.llm.repoID) else {
                throw StepFailure(message: "Model \(config.llm.repoID) is not installed in Ollama.")
            }
        } catch {
            let m = (error as? StepFailure)?.message ?? error.localizedDescription
            throw OrbError.message(m)
        }
    }

    /// Stops all services started by ORB (an Ollama instance ORB did not start is left alone).
    public func stopServices() async {
        await ollama?.stop(); await whisper?.stop(); await piper?.stop()
    }

    /// Hot-swap the active STT model: downloads if needed, stops whisper-server, reconfigures, and restarts.
    public func switchSTT(_ model: CatalogModel, config: inout OrbConfig, progress: (@Sendable (DownloadProgress) -> Void)? = nil) async throws {
        if !downloader.isDownloaded(model) {
            orbState = .downloading; currentOperation = "Downloading \(model.name)"
            _ = try await downloader.download(model) { [weak self] p in
                progress?(p)
                Task { @MainActor in self?.downloadProgress = p }
            }
            downloadProgress = nil
        }
        guard let wBin = RuntimeInstaller().whisperServerPath() else {
            throw OrbError.message("whisper-server not found. Run setup to install it.")
        }
        await whisper?.stop()
        await pm.stop("whisper")
        let wb = WhisperCppBackend(binary: wBin, processManager: pm)
        try await wb.configure(model: model, modelDirectory: downloader.localDirectory(for: model))
        orbState = .initializing; currentOperation = "Restarting STT (\(model.name))"
        try await wb.start()
        whisper = wb
        config.stt = model
        try? Self.saveConfig(config)
        orbState = .ready; currentOperation = "ORB is ready"
    }

    /// Hot-swap the active TTS model: downloads if needed, stops Piper server, reconfigures, and restarts.
    public func switchTTS(_ model: CatalogModel, config: inout OrbConfig, progress: (@Sendable (DownloadProgress) -> Void)? = nil) async throws {
        if !downloader.isDownloaded(model) {
            orbState = .downloading; currentOperation = "Downloading \(model.name)"
            _ = try await downloader.download(model) { [weak self] p in
                progress?(p)
                Task { @MainActor in self?.downloadProgress = p }
            }
            downloadProgress = nil
        }
        let inst = RuntimeInstaller()
        guard FileManager.default.isExecutableFile(atPath: inst.venvPython.path), inst.piperImportable() else {
            throw OrbError.message("Piper environment missing. Re-run setup to recreate it.")
        }
        await piper?.stop()
        await pm.stop("piper")
        let pb = PiperBackend(python: inst.venvPython, processManager: pm)
        try await pb.configure(model: model, modelDirectory: downloader.localDirectory(for: model))
        orbState = .initializing; currentOperation = "Restarting TTS (\(model.name))"
        try await pb.start()
        piper = pb
        config.tts = model
        try? Self.saveConfig(config)
        orbState = .ready; currentOperation = "ORB is ready"
    }

    /// Hot-swap the active LLM model: pulls in Ollama if needed, updates config.
    public func switchLLM(_ model: CatalogModel, config: inout OrbConfig, progress: (@Sendable (DownloadProgress) -> Void)? = nil) async throws {
        guard let oBin = RuntimeInstaller().ollamaPath() else {
            throw OrbError.message("Ollama not found. Run setup to install it.")
        }
        let ob = ollama ?? OllamaBackend(binary: oBin, processManager: pm)
        try await ob.configure(model: model, modelDirectory: Paths.models)
        try await ob.start()
        if !(await ob.hasModel(model.repoID)) {
            orbState = .downloading; currentOperation = "Pulling \(model.repoID)"
            try await ob.pull { [weak self] p in
                progress?(p)
                Task { @MainActor in self?.downloadProgress = p }
            }
            downloadProgress = nil
        }
        ollama = ob
        config.llm = model
        try? Self.saveConfig(config)
        orbState = .ready; currentOperation = "ORB is ready"
    }

    // MARK: Audio
    private func checkAudio() async throws -> String {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        var granted = status == .authorized
        if status == .notDetermined {
            let isApp = Bundle.main.bundleURL.pathExtension == "app"
            if isApp {
                let hasKey = Bundle.main.object(forInfoDictionaryKey: "NSMicrophoneUsageDescription") != nil
                if !hasKey { throw StepFailure(message: "The app bundle lacks NSMicrophoneUsageDescription in Info.plist, so macOS cannot show the microphone prompt.") }
                currentOperation = "Waiting for microphone permission…"
                granted = await AVCaptureDevice.requestAccess(for: .audio)
            } else {
                appendLog("CLI setup: microphone permission will be requested when starting `orb run`.")
                granted = true
            }
        }
        guard granted else {
            throw StepFailure(message: "Microphone access is denied. Enable it in System Settings ▸ Privacy & Security ▸ Microphone, then re-run setup.")
        }
        let inputs = Self.audioDevices(input: true), outputs = Self.audioDevices(input: false)
        guard !inputs.isEmpty else { throw StepFailure(message: "No audio input device found. Connect a microphone.") }
        guard !outputs.isEmpty else { throw StepFailure(message: "No audio output device found. Connect speakers or headphones.") }
        return "Mic authorized; \(inputs.count) input, \(outputs.count) output device(s)"
    }

    nonisolated static func audioDevices(input: Bool) -> [String] {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return [] }
        var names: [String] = []
        for id in ids {
            var sa = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: input ? kAudioDevicePropertyScopeInput : kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
            var s: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &sa, 0, nil, &s) == noErr, s > 0 else { continue }
            var na = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var cf: Unmanaged<CFString>?; var ns = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            if AudioObjectGetPropertyData(id, &na, 0, nil, &ns, &cf) == noErr, let cf { names.append(cf.takeRetainedValue() as String) } else { names.append("device \(id)") }
        }
        return names
    }

    nonisolated static func freeBytes(_ url: URL) -> Int64? {
        let v = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return v?.volumeAvailableCapacityForImportantUsage
    }

    // MARK: End-to-end
    private func endToEnd(_ cfg: OrbConfig) async throws -> String {
        guard let o = ollama, let w = whisper, let p = piper else { throw StepFailure(message: "Backends are not configured.") }
        let phrase = "Hello, this is a test of the voice assistant."
        currentOperation = "TTS: synthesizing test phrase"
        let wav: Data
        do { wav = try await p.synthesize(phrase) } catch { throw StepFailure(message: "TTS synthesis failed: \(error.localizedDescription). See \(Paths.logs.path)/piper.log") }
        guard let dur = WAV.duration(wav), dur > 0.5 else { throw StepFailure(message: "TTS returned invalid or near-empty audio (\(wav.count) bytes).") }

        currentOperation = "STT: transcribing synthesized audio"
        let text: String
        do { text = try await w.transcribe(wav: wav, language: nil) } catch { throw StepFailure(message: "STT failed: \(error.localizedDescription). See \(Paths.logs.path)/whisper.log") }
        appendLog("STT heard: “\(text)”")
        func words(_ s: String) -> Set<String> { Set(s.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init)) }
        let overlap = words(text).intersection(words(phrase)).count
        guard !text.isEmpty, overlap >= 2 else {
            throw StepFailure(message: "STT transcript “\(text)” does not match the synthesized phrase. The STT model or TTS voice may be incompatible.")
        }

        currentOperation = "LLM: generating"
        let reply: String
        do { reply = try await o.quickChat("Reply with one short friendly sentence.", maxTokens: 256) } catch { throw StepFailure(message: "LLM generation failed: \(error.localizedDescription)") }
        guard !reply.isEmpty else { throw StepFailure(message: "LLM \(cfg.llm.repoID) returned an empty response.") }
        appendLog("LLM replied: “\(reply.prefix(120))”")
        return String(format: "TTS %.1fs audio → STT “%@” → LLM replied (%d chars)", dur, text, reply.count)
    }
}
