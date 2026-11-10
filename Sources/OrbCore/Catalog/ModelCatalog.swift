import Foundation

/// Merges the compatibility registry with live HF/Ollama metadata, with an offline JSON cache.
public struct ModelCatalog: ModelCataloging {
    public let registry: CompatibilityRegistry
    public let hf: HFClient
    public let ollamaURL: URL

    public init(registry: CompatibilityRegistry = CompatibilityRegistry(), hf: HFClient = HFClient(),
                ollamaURL: URL = Endpoints.ollama) {
        self.registry = registry; self.hf = hf; self.ollamaURL = ollamaURL
    }

    // MARK: ModelCataloging

    public func featured(kind: ModelKind, hardware: HardwareProfile) async -> [CatalogModel] {
        var models: [CatalogModel]
        switch kind {
        case .llm:
            models = registry.entries(kind: .llm).map { $0.toCatalogModel() }
            let local = await localOllamaModels()
            let known = Set(models.map(\.repoID))
            models += local.filter { !known.contains($0.repoID) }
        case .stt, .tts:
            let base = registry.entries(kind: kind).map { $0.toCatalogModel() }
            let cached = Dictionary(uniqueKeysWithValues: (loadCache(kind) ?? []).map { ($0.id, $0) })
            // Offline fallback: fill live-only fields from the last good cache.
            models = await enrich(base, kind: kind).map { m in
                guard let c = cached[m.id] else { return m }
                var m = m
                if m.downloads == nil { m.downloads = c.downloads; m.likes = c.likes }
                if m.files.contains(where: { $0.sizeBytes == nil }) && !c.files.isEmpty { m.files = c.files; m.sizeBytes = c.sizeBytes }
                return m
            }
            saveCache(models, kind)
        }
        return sortForHardware(models, hardware: hardware)
    }

    public func search(kind: ModelKind, query: String, hardware: HardwareProfile) async throws -> [CatalogModel] {
        let q = query.trimmingCharacters(in: .whitespaces)
        switch kind {
        case .llm:
            let all = await featured(kind: .llm, hardware: hardware)
            guard !q.isEmpty else { return all }
            let terms = q.lowercased().split(separator: " ").map(String.init)
            return all.filter { m in terms.allSatisfy { (m.repoID + " " + m.name).lowercased().contains($0) } }
        case .stt, .tts:
            let tag = kind == .stt ? "automatic-speech-recognition" : "text-to-speech"
            var results: [CatalogModel] = []
            let verified = registry.entries(kind: kind).map { $0.toCatalogModel() }
            let terms = q.lowercased().split(separator: " ").map(String.init)
            let vMatches = verified.filter { m in terms.allSatisfy { (m.repoID + " " + m.name + " " + m.id).lowercased().contains($0) } }
            results += await enrich(vMatches, kind: kind)

            // Direct HF repo inspection if the query looks like `owner/repo` or `owner/repo#variant`
            if q.contains("/") && !q.contains(" ") {
                let parts = q.split(separator: "#", maxSplits: 1).map(String.init)
                let repoCandidate = parts[0]
                let variantFilter = parts.count > 1 ? parts[1].lowercased() : nil
                if let tree = try? await hf.tree(repo: repoCandidate, recursive: true) {
                    let files = tree.filter { $0.type == "file" }.map { ModelFile(path: $0.path, sizeBytes: $0.size, sha256: $0.sha256) }
                    let s = (try? await hf.modelInfo(repo: repoCandidate))?.0
                    var direct = registry.heuristicModels(kind: kind, repo: repoCandidate, files: files, summary: s)
                    if let vf = variantFilter {
                        direct = direct.filter { $0.id.lowercased().contains(vf) || $0.name.lowercased().contains(vf) || $0.files.contains(where: { $0.path.lowercased().contains(vf) }) }
                    }
                    let existing = Set(results.map(\.id))
                    results += direct.filter { !existing.contains($0.id) }
                }
            }

            let hits: [HFModelSummary]
            do { hits = try await hf.searchModels(query: q, pipelineTag: tag, limit: 20) }
            catch { if results.isEmpty { throw error } else { return results } }
            let hf = self.hf, reg = registry
            let found = await withTaskGroup(of: [CatalogModel].self) { group -> [CatalogModel] in
                for h in hits.prefix(12) {
                    group.addTask {
                        guard let tree = try? await hf.tree(repo: h.id, recursive: kind == .tts) else { return [] }
                        let files = tree.filter { $0.type == "file" }.map { ModelFile(path: $0.path, sizeBytes: $0.size, sha256: $0.sha256) }
                        return reg.heuristicModels(kind: kind, repo: h.id, files: files, summary: h)
                    }
                }
                var all: [CatalogModel] = []
                for await r in group { all += r }
                return all
            }
            let existingIDs = Set(results.map(\.id))
            results += found.filter { !existingIDs.contains($0.id) }.sorted { ($0.downloads ?? 0) > ($1.downloads ?? 0) }
            return results.filter { $0.minMemoryGB <= max(hardware.memoryGB, 1) * 1.0 || $0.compatibility == .verified }
        }
    }

    public func recommended(kind: ModelKind, hardware: HardwareProfile) async -> CatalogModel? {
        let id = Self.recommendedID(kind: kind, hardware: hardware)
        return registry.entry(id: id)?.toCatalogModel()
    }

    public static func recommendedID(kind: ModelKind, hardware hw: HardwareProfile) -> String {
        switch kind {
        case .llm:
            let m = hw.memoryGB
            let tag = m < 8 ? "llama3.2:1b" : m < 12 ? "llama3.2:3b" : m < 24 ? "qwen2.5:7b" : m < 48 ? "qwen3:8b" : "qwen3:14b"
            return "llm:\(tag)"
        case .stt:
            let v: String
            switch hw.tier {
            case .entry: v = hw.memoryGB < 6 ? "ggml-base.en" : "ggml-small.en"
            case .standard: v = "ggml-small.en"
            case .high, .ultra: v = "ggml-large-v3-turbo-q5_0"
            }
            return "stt:\(CompatibilityRegistry.whisperRepo)#\(v)"
        case .tts:
            return "tts:\(CompatibilityRegistry.piperRepo)#en_US-lessac-medium"
        }
    }

    // MARK: Live merge

    private func enrich(_ models: [CatalogModel], kind: ModelKind) async -> [CatalogModel] {
        let repos = Set(models.map(\.repoID))
        var summaries: [String: HFModelSummary] = [:]
        var infos: [String: [String: ModelFile]] = [:]
        for repo in repos {
            if kind == .stt, let (s, files) = try? await hf.modelInfo(repo: repo) {
                summaries[repo] = s
                infos[repo] = Dictionary(files.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
            } else if kind == .tts, let hits = try? await hf.searchModels(query: repo.components(separatedBy: "/").last ?? repo, pipelineTag: "text-to-speech", limit: 10),
                      let s = hits.first(where: { $0.id == repo }) {
                summaries[repo] = s
            }
        }
        // TTS: resolve per-voice file sizes via tree API (small directories), concurrently.
        let hf = self.hf
        var resolved: [String: [ModelFile]] = [:]
        if kind == .tts {
            await withTaskGroup(of: (String, [ModelFile]).self) { g in
                for m in models { g.addTask { (m.id, await hf.resolveFiles(repo: m.repoID, paths: m.files.map(\.path))) } }
                for await (id, f) in g { resolved[id] = f }
            }
        }
        return models.map { m in
            var m = m
            if let s = summaries[m.repoID] {
                m.downloads = s.downloads; m.likes = s.likes
                if let l = s.license, m.kind == .stt { m.license = l }
            }
            if let table = infos[m.repoID] {
                m.files = m.files.map { table[$0.path] ?? $0 }
            } else if let f = resolved[m.id] { m.files = f }
            let total = m.files.compactMap(\.sizeBytes).reduce(0, +)
            if total > 0 && m.files.allSatisfy({ $0.sizeBytes != nil }) { m.sizeBytes = total }
            return m
        }
    }

    private func sortForHardware(_ models: [CatalogModel], hardware: HardwareProfile) -> [CatalogModel] {
        let rec = Self.recommendedID(kind: models.first?.kind ?? .llm, hardware: hardware)
        let ok = models.filter { $0.minMemoryGB <= hardware.memoryGB }
        let rest = models.filter { $0.minMemoryGB > hardware.memoryGB }
        let ordered = ok.sorted { a, b in
            if a.id == rec { return true }
            if b.id == rec { return false }
            return a.minMemoryGB < b.minMemoryGB
        }
        // keep recommended first, then by ascending requirement, then those that don't fit
        return ordered + rest
    }

    // MARK: Ollama local

    /// Locally-installed models via GET /api/tags; empty when Ollama is unreachable.
    public func localOllamaModels() async -> [CatalogModel] {
        var req = URLRequest(url: ollamaURL.appendingPathComponent("api/tags"), timeoutInterval: 2)
        req.httpMethod = "GET"
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let arr = obj["models"] as? [[String: Any]] else { return [] }
        return arr.compactMap { d in
            guard let name = (d["name"] as? String) ?? (d["model"] as? String) else { return nil }
            let size = (d["size"] as? NSNumber)?.int64Value ?? 0
            let det = d["details"] as? [String: Any]
            let params = det?["parameter_size"] as? String ?? ""
            return CatalogModel(id: "llm:\(name)", kind: .llm, name: name + " (installed)", repoID: name, backend: .ollama,
                                sizeBytes: size, languages: ["multilingual"], quality: "Installed",
                                minMemoryGB: max(2, (Double(size) / 1e9 * 2).rounded()),
                                compatibility: .verified, summary: "Installed locally in Ollama \(params)")
        }
    }

    // MARK: Cache

    private func cacheURL(_ kind: ModelKind) -> URL { Paths.cache.appendingPathComponent("catalog-\(kind.rawValue).json") }
    private func loadCache(_ kind: ModelKind) -> [CatalogModel]? {
        guard let d = try? Data(contentsOf: cacheURL(kind)) else { return nil }
        return try? JSONDecoder().decode([CatalogModel].self, from: d)
    }
    private func saveCache(_ models: [CatalogModel], _ kind: ModelKind) {
        try? FileManager.default.createDirectory(at: Paths.cache, withIntermediateDirectories: true)
        if let d = try? JSONEncoder().encode(models) { try? d.write(to: cacheURL(kind), options: .atomic) }
    }
}
