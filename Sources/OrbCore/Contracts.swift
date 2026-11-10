import Foundation

// =====================================================================
// ORB shared contracts. Every module codes against these types.
// Do NOT change signatures without coordinating with the lead agent.
// =====================================================================

public enum ModelKind: String, Codable, CaseIterable, Sendable { case llm, stt, tts }

/// Inference backends. Add cases here to support new engines.
public enum BackendID: String, Codable, Sendable {
    case ollama      // LLM via Ollama (http://127.0.0.1:11434)
    case whispercpp  // STT via whisper.cpp `whisper-server` (ggml-*.bin from HF ggerganov/whisper.cpp)
    case piper       // TTS via piper-tts in an isolated venv (onnx voices from HF rhasspy/piper-voices)
}

public struct ModelFile: Codable, Hashable, Sendable {
    public var path: String          // path inside HF repo (or ollama tag for LLM, then empty)
    public var sizeBytes: Int64?
    public var sha256: String?       // from HF LFS metadata when available
    public init(path: String, sizeBytes: Int64? = nil, sha256: String? = nil) {
        self.path = path; self.sizeBytes = sizeBytes; self.sha256 = sha256
    }
}

public enum Compatibility: String, Codable, Sendable {
    case verified      // in the compatibility registry, tested architecture/format/backend
    case experimental  // heuristically matched, may not run
}

public struct CatalogModel: Codable, Identifiable, Hashable, Sendable {
    public var id: String               // "<kind>:<repoID or ollama tag>[#variant]"
    public var kind: ModelKind
    public var name: String
    public var repoID: String           // HF repo id, or Ollama tag e.g. "llama3.2:3b"
    public var backend: BackendID
    public var files: [ModelFile]       // files to download (empty for ollama; ollama pulls itself)
    public var sizeBytes: Int64         // total download size (best known)
    public var languages: [String]      // ISO codes, ["multilingual"] allowed
    public var license: String?
    public var quality: String          // human label e.g. "Fast", "Balanced", "High"
    public var minMemoryGB: Double
    public var compatibility: Compatibility
    public var summary: String
    public var downloads: Int?
    public var likes: Int?
    public var voice: String?           // TTS: voice id/name
    public init(id: String, kind: ModelKind, name: String, repoID: String, backend: BackendID,
                files: [ModelFile] = [], sizeBytes: Int64 = 0, languages: [String] = [],
                license: String? = nil, quality: String = "", minMemoryGB: Double = 0,
                compatibility: Compatibility = .experimental, summary: String = "",
                downloads: Int? = nil, likes: Int? = nil, voice: String? = nil) {
        self.id = id; self.kind = kind; self.name = name; self.repoID = repoID; self.backend = backend
        self.files = files; self.sizeBytes = sizeBytes; self.languages = languages; self.license = license
        self.quality = quality; self.minMemoryGB = minMemoryGB; self.compatibility = compatibility
        self.summary = summary; self.downloads = downloads; self.likes = likes; self.voice = voice
    }
}

public struct HardwareProfile: Codable, Sendable {
    public var chip: String             // "Apple M3 Pro"
    public var isAppleSilicon: Bool
    public var generation: Int          // 1,2,3.. (0 if unknown/Intel)
    public var performanceCores: Int
    public var totalCores: Int
    public var gpuCores: Int?
    public var memoryGB: Double
    public var osVersion: String
    public var freeDiskGB: Double
    public var tier: Tier
    public enum Tier: String, Codable, Sendable { case entry, standard, high, ultra } // by memory/chip
    public init(chip: String, isAppleSilicon: Bool, generation: Int, performanceCores: Int, totalCores: Int,
                gpuCores: Int?, memoryGB: Double, osVersion: String, freeDiskGB: Double, tier: Tier) {
        self.chip = chip; self.isAppleSilicon = isAppleSilicon; self.generation = generation
        self.performanceCores = performanceCores; self.totalCores = totalCores; self.gpuCores = gpuCores
        self.memoryGB = memoryGB; self.osVersion = osVersion; self.freeDiskGB = freeDiskGB; self.tier = tier
    }
}

/// The user's chosen stack, persisted at OrbPaths.config.
public struct OrbConfig: Codable, Sendable {
    public var llm: CatalogModel
    public var stt: CatalogModel
    public var tts: CatalogModel
    public var systemPrompt: String = "You are ORB, a concise, friendly voice assistant. Answer in one to three short spoken sentences. No markdown."
    public var inputDeviceUID: String?
    public var outputDeviceUID: String?
    public var launchAtLogin: Bool = false
    public var autoStartAgent: Bool = false
    public var setupCompleted: Bool = false      // true ONLY after SetupEngine verification passes
    public var lastVerifiedAt: Date?
    public init(llm: CatalogModel, stt: CatalogModel, tts: CatalogModel) { self.llm = llm; self.stt = stt; self.tts = tts }
}

public enum OrbState: String, Codable, Sendable, CaseIterable {
    case idle, downloading, installing, initializing, ready, listening, thinking, speaking, error
}

/// Fixed local endpoints (loopback only).
public enum Endpoints {
    public static let ollama = URL(string: "http://127.0.0.1:11434")!
    public static let whisper = URL(string: "http://127.0.0.1:18181")!   // POST /inference (multipart: file, response_format=json, language) -> {"text": "..."}
    public static let tts = URL(string: "http://127.0.0.1:18182")!       // our piper server: GET /health, POST /tts {"text": "..."} -> audio/wav
}

public struct Paths: Sendable {
    public static let root: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/ORB", isDirectory: true)
    public static var models: URL { override ?? root.appendingPathComponent("models", isDirectory: true) }
    public static var runtimes: URL { root.appendingPathComponent("runtimes", isDirectory: true) }
    public static var venv: URL { runtimes.appendingPathComponent("venv", isDirectory: true) }
    public static var bin: URL { runtimes.appendingPathComponent("bin", isDirectory: true) }
    public static var logs: URL { root.appendingPathComponent("logs", isDirectory: true) }
    public static var config: URL { root.appendingPathComponent("config.json") }
    public static var cache: URL { root.appendingPathComponent("cache", isDirectory: true) }
    /// User-overridable model storage directory (Settings). Set by app at launch from UserDefaults "modelsDir".
    nonisolated(unsafe) public static var override: URL? = nil
    public static func ensureAll() throws {
        for u in [root, models, runtimes, bin, logs, cache] {
            try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        }
    }
}

// ---------- Service protocols ----------

public protocol HardwareDetecting { func detect() async -> HardwareProfile }

public protocol ModelCataloging: Sendable {
    /// Curated + live-verified recommendations (live HF metadata merged into the compatibility registry).
    func featured(kind: ModelKind, hardware: HardwareProfile) async -> [CatalogModel]
    /// Live HF Hub search (STT/TTS) or Ollama-library-style matching (LLM). Results tagged verified/experimental.
    func search(kind: ModelKind, query: String, hardware: HardwareProfile) async throws -> [CatalogModel]
    /// Best default for the hardware.
    func recommended(kind: ModelKind, hardware: HardwareProfile) async -> CatalogModel?
}

public struct DownloadProgress: Sendable {
    public var fileName: String
    public var bytesDone: Int64
    public var bytesTotal: Int64
    public var bytesPerSecond: Double
    public var etaSeconds: Double?
    public init(fileName: String, bytesDone: Int64, bytesTotal: Int64, bytesPerSecond: Double, etaSeconds: Double?) {
        self.fileName = fileName; self.bytesDone = bytesDone; self.bytesTotal = bytesTotal
        self.bytesPerSecond = bytesPerSecond; self.etaSeconds = etaSeconds
    }
}

public protocol ModelDownloading: Sendable {
    /// Resumable (HTTP Range, .part files), checksum-verified download of all files of a HF model into Paths.models.
    /// Returns the local directory. Throws CancellationError on cancel (partials are kept for resume).
    func download(_ model: CatalogModel, progress: @escaping @Sendable (DownloadProgress) -> Void) async throws -> URL
    func localDirectory(for model: CatalogModel) -> URL
    func isDownloaded(_ model: CatalogModel) -> Bool
}

public enum SetupStepID: String, CaseIterable, Codable, Sendable {
    case detectHardware, validateModels, checkDisk, installRuntimes, createEnvironment, downloadModels
    case verifyDownloads, configureBackends, configureAudio, startServices, connectPipeline, endToEndTest, markReady
}
public enum StepStatus: String, Codable, Sendable { case pending, running, done, failed, skipped }

public struct SetupStep: Identifiable, Sendable {
    public var id: SetupStepID
    public var title: String
    public var status: StepStatus = .pending
    public var detail: String = ""
    public init(id: SetupStepID, title: String) { self.id = id; self.title = title }
}

public protocol PipelineEvents: AnyObject, Sendable {}

public enum OrbError: Error, LocalizedError, Sendable {
    case message(String)
    public var errorDescription: String? { if case .message(let m) = self { return m }; return nil }
}

// ---------- Voice engine client protocols (HTTP clients; voice module implements) ----------
public struct ChatMessage: Codable, Sendable, Hashable {
    public var role: String   // system | user | assistant
    public var content: String
    public init(role: String, content: String) { self.role = role; self.content = content }
}
public protocol STTClient: Sendable { func transcribe(wav: Data, language: String?) async throws -> String }
public protocol LLMClient: Sendable { func stream(model: String, messages: [ChatMessage]) -> AsyncThrowingStream<String, Error> }
public protocol TTSClient: Sendable { func synthesize(text: String) async throws -> Data /* wav */ }
