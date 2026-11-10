import Foundation

public enum ModelFileFormat: String, Codable, Sendable { case ggml, onnxPair, ollama }

/// A verified (tested) model description: architecture, backend, format and install procedure.
public struct RegistryEntry: Codable, Sendable, Hashable {
    public var kind: ModelKind
    public var variant: String          // unique within repo, e.g. "ggml-tiny.en"
    public var name: String
    public var repoID: String
    public var architecture: String
    public var backend: BackendID
    public var format: ModelFileFormat
    public var filePaths: [String]      // paths inside the HF repo (empty for ollama)
    public var approxSizeBytes: Int64
    public var languages: [String]
    public var license: String?
    public var quality: String
    public var minMemoryGB: Double
    public var summary: String
    public var voice: String?
    public var installProcedure: String

    public var id: String { "\(kind.rawValue):\(repoID)" + (variant.isEmpty ? "" : "#\(variant)") }

    public func toCatalogModel() -> CatalogModel {
        CatalogModel(id: id, kind: kind, name: name, repoID: repoID, backend: backend,
                     files: filePaths.map { ModelFile(path: $0) }, sizeBytes: approxSizeBytes,
                     languages: languages, license: license, quality: quality, minMemoryGB: minMemoryGB,
                     compatibility: .verified, summary: summary, voice: voice)
    }
}

/// Table of verified models plus heuristics that classify unknown HF repos as experimental.
public struct CompatibilityRegistry: Sendable {
    public static let whisperRepo = "ggerganov/whisper.cpp"
    public static let piperRepo = "rhasspy/piper-voices"

    public let entries: [RegistryEntry]

    public init(entries: [RegistryEntry] = CompatibilityRegistry.builtin) { self.entries = entries }

    public func entries(kind: ModelKind) -> [RegistryEntry] { entries.filter { $0.kind == kind } }
    public func entry(id: String) -> RegistryEntry? { entries.first { $0.id == id } }

    /// Verified entries that belong to a repo (any kind).
    public func entries(repo: String) -> [RegistryEntry] { entries.filter { $0.repoID == repo } }
    public func isVerifiedRepo(_ repo: String) -> Bool { entries.contains { $0.repoID == repo } }

    // MARK: Heuristics

    /// Heuristic match from a repo's file list. Returns experimental models (backend + files) or [] if unrecognised.
    public func heuristicModels(kind: ModelKind, repo: String, files: [ModelFile], summary s: HFModelSummary?) -> [CatalogModel] {
        var out: [CatalogModel] = []
        let lic = s?.license
        let langs = (s?.languages.isEmpty ?? true) ? ["multilingual"] : s!.languages
        switch kind {
        case .stt:
            for f in files where f.path.hasSuffix(".bin") && !f.path.contains("/") {
                let base = (f.path as NSString).deletingPathExtension
                out.append(CatalogModel(id: "stt:\(repo)#\(base)", kind: .stt, name: "\(base) (\(repo))", repoID: repo, backend: .whispercpp,
                                        files: [f], sizeBytes: f.sizeBytes ?? 0, languages: langs, license: lic,
                                        quality: "Custom / HF", minMemoryGB: max(1, Double(f.sizeBytes ?? 0) / 1e9 * 3),
                                        compatibility: .experimental, summary: "ggml Whisper weights from \(repo)",
                                        downloads: s?.downloads, likes: s?.likes))
            }
        case .tts:
            let onnx = Set(files.map(\.path).filter { $0.hasSuffix(".onnx") })
            for p in onnx.sorted() {
                guard let cfg = files.first(where: { $0.path == p + ".json" }), let m = files.first(where: { $0.path == p }) else { continue }
                let base = ((p as NSString).lastPathComponent as NSString).deletingPathExtension
                out.append(CatalogModel(id: "tts:\(repo)#\(base)", kind: .tts, name: "\(base) (\(repo))", repoID: repo, backend: .piper,
                                        files: [m, cfg], sizeBytes: (m.sizeBytes ?? 0) + (cfg.sizeBytes ?? 0), languages: langs,
                                        license: lic, quality: "Custom / HF", minMemoryGB: 1, compatibility: .experimental,
                                        summary: "Piper ONNX voice from \(repo)", downloads: s?.downloads,
                                        likes: s?.likes, voice: base))
            }
        case .llm: break
        }
        return out
    }

    // MARK: Custom / Bring-Your-Own Local Models

    /// Create a custom STT CatalogModel from a local whisper.cpp `.bin` file on disk.
    public static func customSTTFromLocalFile(_ url: URL) throws -> CatalogModel {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else {
            throw OrbError.message("Local STT file not found at \(url.path)")
        }
        guard url.pathExtension.lowercased() == "bin" else {
            throw OrbError.message("Custom STT model must be a whisper.cpp ggml `.bin` file (got .\(url.pathExtension)).")
        }
        let sz = ((try? fm.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0
        guard sz > 1024 else { throw OrbError.message("Local STT `.bin` file appears empty (\(sz) bytes).") }
        let base = url.deletingPathExtension().lastPathComponent
        let lang = base.hasSuffix(".en") ? ["en"] : ["multilingual"]
        return CatalogModel(
            id: "stt:local#\(base)",
            kind: .stt,
            name: "\(base) (Local)",
            repoID: url.deletingLastPathComponent().path,
            backend: .whispercpp,
            files: [ModelFile(path: url.path, sizeBytes: sz)],
            sizeBytes: sz,
            languages: lang,
            license: "local",
            quality: "Custom Local",
            minMemoryGB: max(1, Double(sz) / 1e9 * 2.5),
            compatibility: .verified,
            summary: "Custom local whisper.cpp model (\(url.path))"
        )
    }

    /// Create a custom TTS CatalogModel from a local Piper `.onnx` file (expects `<file>.onnx.json` alongside it).
    public static func customTTSFromLocalFile(_ onnxURL: URL) throws -> CatalogModel {
        let fm = FileManager.default
        let actualOnnx: URL = onnxURL.path.hasSuffix(".onnx.json")
            ? URL(fileURLWithPath: String(onnxURL.path.dropLast(5)))
            : onnxURL
        guard fm.fileExists(atPath: actualOnnx.path), actualOnnx.pathExtension.lowercased() == "onnx" else {
            throw OrbError.message("Custom TTS voice must be a Piper `.onnx` model file (not found at \(actualOnnx.path)).")
        }
        let jsonURL = URL(fileURLWithPath: actualOnnx.path + ".json")
        guard fm.fileExists(atPath: jsonURL.path) else {
            throw OrbError.message("Missing companion config file `\(jsonURL.lastPathComponent)` in \(actualOnnx.deletingLastPathComponent().path). Piper requires both `.onnx` and `.onnx.json`.")
        }
        let onnxSize = ((try? fm.attributesOfItem(atPath: actualOnnx.path))?[.size] as? NSNumber)?.int64Value ?? 0
        let jsonSize = ((try? fm.attributesOfItem(atPath: jsonURL.path))?[.size] as? NSNumber)?.int64Value ?? 0
        let base = actualOnnx.deletingPathExtension().lastPathComponent
        let langPrefix = String(base.prefix(2)).lowercased()
        return CatalogModel(
            id: "tts:local#\(base)",
            kind: .tts,
            name: "\(base) (Local)",
            repoID: actualOnnx.deletingLastPathComponent().path,
            backend: .piper,
            files: [
                ModelFile(path: actualOnnx.path, sizeBytes: onnxSize),
                ModelFile(path: jsonURL.path, sizeBytes: jsonSize)
            ],
            sizeBytes: onnxSize + jsonSize,
            languages: [langPrefix.isEmpty ? "en" : langPrefix],
            license: "local",
            quality: "Custom Local",
            minMemoryGB: 1,
            compatibility: .verified,
            summary: "Custom local Piper ONNX voice (\(actualOnnx.path))",
            voice: base
        )
    }

    /// Create a custom LLM CatalogModel for any arbitrary Ollama tag (e.g. `deepseek-r1:8b`, `hf.co/user/repo`).
    public static func customLLMFromTag(_ tag: String) -> CatalogModel {
        let clean = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        return CatalogModel(
            id: "llm:\(clean)",
            kind: .llm,
            name: "\(clean) (Custom)",
            repoID: clean,
            backend: .ollama,
            files: [],
            sizeBytes: 0,
            languages: ["multilingual"],
            license: "custom",
            quality: "Custom Tag",
            minMemoryGB: 2,
            compatibility: .verified,
            summary: "Custom Ollama model tag `\(clean)`"
        )
    }

    // MARK: Builtin table

    private static func whisper(_ file: String, _ name: String, _ size: Int64, _ lang: [String], _ q: String, _ mem: Double, _ note: String) -> RegistryEntry {
        RegistryEntry(kind: .stt, variant: file, name: name, repoID: whisperRepo, architecture: "whisper (ggml)", backend: .whispercpp,
                      format: .ggml, filePaths: [file + ".bin"], approxSizeBytes: size, languages: lang, license: "mit",
                      quality: q, minMemoryGB: mem, summary: note, voice: nil,
                      installProcedure: "Download \(file).bin into models dir; run whisper-server -m <file> --port 18181")
    }

    private static func piper(_ lang: String, _ locale: String, _ voice: String, _ quality: String, _ label: String) -> RegistryEntry {
        let base = "\(locale)-\(voice)-\(quality)"
        let dir = "\(lang)/\(locale)/\(voice)/\(quality)/"
        let size: Int64 = quality == "high" ? 114_000_000 : (quality == "x_low" ? 20_000_000 : (quality == "low" ? 63_000_000 : 63_000_000))
        let q = quality == "high" ? "High" : (quality == "medium" ? "Balanced" : "Fast")
        return RegistryEntry(kind: .tts, variant: base, name: "\(label) (\(locale), \(quality))", repoID: piperRepo,
                             architecture: "VITS (Piper)", backend: .piper, format: .onnxPair,
                             filePaths: [dir + base + ".onnx", dir + base + ".onnx.json"], approxSizeBytes: size,
                             languages: [lang], license: "see voice card (mostly MIT/CC)", quality: q, minMemoryGB: 1,
                             summary: "Piper neural voice \(label)", voice: base,
                             installProcedure: "Download .onnx + .onnx.json; serve with piper-tts in isolated venv on :18182")
    }

    private static func ollama(_ tag: String, _ name: String, _ gb: Double, _ mem: Double, _ q: String, _ lic: String, _ note: String) -> RegistryEntry {
        RegistryEntry(kind: .llm, variant: "", name: name, repoID: tag, architecture: "transformer (GGUF)", backend: .ollama,
                      format: .ollama, filePaths: [], approxSizeBytes: Int64(gb * 1_000_000_000), languages: ["multilingual"],
                      license: lic, quality: q, minMemoryGB: mem, summary: note, voice: nil,
                      installProcedure: "ollama pull \(tag)")
    }

    public static let builtin: [RegistryEntry] = [
        // STT — whisper.cpp
        whisper("ggml-tiny.en", "Whisper Tiny (English)", 77_704_715, ["en"], "Fast", 1, "Fastest, lowest accuracy"),
        whisper("ggml-base.en", "Whisper Base (English)", 147_964_211, ["en"], "Fast", 2, "Good speed/accuracy for light use"),
        whisper("ggml-small.en", "Whisper Small (English)", 487_614_201, ["en"], "Balanced", 4, "Solid English accuracy"),
        whisper("ggml-small-q5_1", "Whisper Small multilingual (Q5_1)", 190_085_487, ["multilingual"], "Balanced", 3, "Compact multilingual"),
        whisper("ggml-medium-q5_0", "Whisper Medium multilingual (Q5_0)", 539_212_467, ["multilingual"], "High", 6, "High accuracy multilingual"),
        whisper("ggml-large-v3-turbo-q5_0", "Whisper Large v3 Turbo (Q5_0)", 574_041_195, ["multilingual"], "High", 8, "Near-large accuracy, fast"),
        whisper("ggml-large-v3-turbo", "Whisper Large v3 Turbo", 1_624_555_275, ["multilingual"], "Best", 12, "Full-precision turbo; best accuracy"),
        // TTS — Piper
        piper("en", "en_US", "lessac", "medium", "Lessac"),
        piper("en", "en_US", "lessac", "high", "Lessac"),
        piper("en", "en_US", "amy", "medium", "Amy"),
        piper("en", "en_US", "ryan", "high", "Ryan"),
        piper("en", "en_US", "joe", "medium", "Joe"),
        piper("en", "en_GB", "alan", "medium", "Alan"),
        piper("en", "en_GB", "jenny_dioco", "medium", "Jenny"),
        piper("de", "de_DE", "thorsten", "medium", "Thorsten"),
        piper("fr", "fr_FR", "siwis", "medium", "Siwis"),
        piper("es", "es_ES", "davefx", "medium", "Davefx"),
        piper("es", "es_MX", "ald", "medium", "Ald"),
        // LLM — Ollama
        ollama("qwen2.5:0.5b", "Qwen 2.5 0.5B", 0.4, 2, "Fast", "apache-2.0", "Ultra-fast compact model"),
        ollama("smollm2:360m", "SmolLM2 360M", 0.3, 2, "Fast", "apache-2.0", "Tiny HuggingFace assistant"),
        ollama("llama3.2:1b", "Llama 3.2 1B", 1.3, 4, "Fast", "llama3.2", "Tiny, quick replies"),
        ollama("llama3.2:3b", "Llama 3.2 3B", 2.0, 6, "Balanced", "llama3.2", "Good small assistant"),
        ollama("gemma2:2b", "Gemma 2 2B", 1.6, 5, "Fast", "gemma", "Google compact model"),
        ollama("phi3.5", "Phi 3.5 Mini", 2.2, 6, "Balanced", "mit", "Strong reasoning for size"),
        ollama("qwen2.5:3b", "Qwen 2.5 3B", 1.9, 6, "Balanced", "qwen-research", "Multilingual small model"),
        ollama("qwen2.5:7b", "Qwen 2.5 7B", 4.7, 10, "High", "apache-2.0", "Capable multilingual 7B"),
        ollama("llama3.1:8b", "Llama 3.1 8B", 4.9, 12, "High", "llama3.1", "Strong general 8B"),
        ollama("qwen3:1.7b", "Qwen 3 1.7B", 1.4, 4, "Fast", "apache-2.0", "Small Qwen 3"),
        ollama("qwen3:4b", "Qwen 3 4B", 2.5, 7, "Balanced", "apache-2.0", "Qwen 3 mid-size"),
        ollama("qwen3:8b", "Qwen 3 8B", 5.2, 12, "High", "apache-2.0", "Qwen 3 8B"),
        ollama("qwen3:14b", "Qwen 3 14B", 9.3, 20, "Best", "apache-2.0", "Qwen 3 14B for large-memory Macs"),
    ]
}
