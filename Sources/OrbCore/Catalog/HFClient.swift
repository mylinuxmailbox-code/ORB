import Foundation

public struct HFModelSummary: Sendable, Hashable {
    public var id: String
    public var downloads: Int?
    public var likes: Int?
    public var pipelineTag: String?
    public var tags: [String]
    public var license: String?
    public var languages: [String]
}

public struct HFTreeEntry: Sendable, Hashable {
    public var type: String   // "file" | "directory"
    public var path: String
    public var size: Int64?
    public var sha256: String?   // LFS oid (sha256) when LFS-backed
}

/// Minimal Hugging Face Hub API client. Uses HF_TOKEN from the environment when set.
public actor HFClient {
    public static let base = URL(string: "https://huggingface.co")!
    private let session: URLSession
    private let token: String?

    public init(session: URLSession = .shared, token: String? = ProcessInfo.processInfo.environment["HF_TOKEN"]) {
        self.session = session
        self.token = (token?.isEmpty == false) ? token : nil
    }

    private func getJSON(_ url: URL) async throws -> Any {
        var req = URLRequest(url: url, timeoutInterval: 20)
        if let t = token { req.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization") }
        let (data, resp) = try await session.data(for: req)
        if let h = resp as? HTTPURLResponse, !(200..<300).contains(h.statusCode) {
            throw OrbError.message("Hugging Face returned HTTP \(h.statusCode) for \(url.path)")
        }
        return try JSONSerialization.jsonObject(with: data)
    }

    private func url(_ path: String, _ query: [URLQueryItem] = []) -> URL {
        var c = URLComponents(url: Self.base, resolvingAgainstBaseURL: false)!
        c.path = path
        if !query.isEmpty { c.queryItems = query }
        return c.url!
    }

    static func summary(_ d: [String: Any]) -> HFModelSummary? {
        guard let id = (d["id"] as? String) ?? (d["modelId"] as? String) else { return nil }
        let tags = d["tags"] as? [String] ?? []
        let lic = tags.first { $0.hasPrefix("license:") }.map { String($0.dropFirst(8)) }
            ?? ((d["cardData"] as? [String: Any])?["license"] as? String)
        let langs = tags.filter { $0.count <= 3 && $0.allSatisfy { $0.isLowercase && $0.isLetter } }
        return HFModelSummary(id: id, downloads: d["downloads"] as? Int, likes: d["likes"] as? Int,
                              pipelineTag: d["pipeline_tag"] as? String, tags: tags, license: lic, languages: langs)
    }

    /// GET /api/models?search=..&pipeline_tag=..&sort=downloads
    public func searchModels(query: String, pipelineTag: String, limit: Int = 30) async throws -> [HFModelSummary] {
        var items = [URLQueryItem(name: "pipeline_tag", value: pipelineTag),
                     URLQueryItem(name: "sort", value: "downloads"),
                     URLQueryItem(name: "direction", value: "-1"),
                     URLQueryItem(name: "limit", value: String(limit))]
        if !query.isEmpty { items.insert(URLQueryItem(name: "search", value: query), at: 0) }
        let json = try await getJSON(url("/api/models", items))
        return (json as? [[String: Any]] ?? []).compactMap(Self.summary)
    }

    /// GET /api/models/<repo>?blobs=true — metadata plus file sizes/LFS sha256.
    public func modelInfo(repo: String) async throws -> (HFModelSummary, [ModelFile]) {
        let json = try await getJSON(url("/api/models/\(repo)", [URLQueryItem(name: "blobs", value: "true")]))
        guard let d = json as? [String: Any], let s = Self.summary(d) else { throw OrbError.message("Bad HF response for \(repo)") }
        let files = (d["siblings"] as? [[String: Any]] ?? []).compactMap { f -> ModelFile? in
            guard let p = f["rfilename"] as? String else { return nil }
            let size = (f["size"] as? NSNumber)?.int64Value
            let sha = (f["lfs"] as? [String: Any])?["sha256"] as? String
            return ModelFile(path: p, sizeBytes: size, sha256: sha)
        }
        return (s, files)
    }

    /// GET /api/models/<repo>/tree/main[/<path>]?recursive=
    public func tree(repo: String, path: String = "", recursive: Bool = false) async throws -> [HFTreeEntry] {
        var p = "/api/models/\(repo)/tree/main"
        if !path.isEmpty { p += "/" + path }
        let items = recursive ? [URLQueryItem(name: "recursive", value: "true")] : []
        let json = try await getJSON(url(p, items))
        return (json as? [[String: Any]] ?? []).compactMap { e in
            guard let t = e["type"] as? String, let pa = e["path"] as? String else { return nil }
            let lfs = e["lfs"] as? [String: Any]
            return HFTreeEntry(type: t, path: pa, size: (e["size"] as? NSNumber)?.int64Value, sha256: lfs?["oid"] as? String)
        }
    }

    /// Resolve concrete ModelFiles (size + sha256) for specific paths in a repo directory.
    public func resolveFiles(repo: String, paths: [String]) async -> [ModelFile] {
        // group by parent directory to minimise requests
        var byDir: [String: [String]] = [:]
        for p in paths { byDir[(p as NSString).deletingLastPathComponent, default: []].append(p) }
        var out: [String: ModelFile] = [:]
        for (dir, ps) in byDir {
            if let entries = try? await tree(repo: repo, path: dir) {
                for e in entries where ps.contains(e.path) {
                    out[e.path] = ModelFile(path: e.path, sizeBytes: e.size, sha256: e.sha256)
                }
            }
        }
        return paths.map { out[$0] ?? ModelFile(path: $0) }
    }
}
