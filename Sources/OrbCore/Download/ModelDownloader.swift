import Foundation
import CryptoKit

/// Resumable HF downloader: .part files + HTTP Range, sha256 verification, progress with speed/ETA.
public final class ModelDownloader: ModelDownloading {
    private let session: URLSession
    private let token: String?

    public init(session: URLSession = .shared, token: String? = ProcessInfo.processInfo.environment["HF_TOKEN"]) {
        self.session = session
        self.token = (token?.isEmpty == false) ? token : nil
    }

    public static func sanitize(_ repo: String) -> String {
        String(repo.map { $0.isLetter || $0.isNumber || "-_.".contains($0) ? $0 : "_" })
    }

    public func localDirectory(for model: CatalogModel) -> URL {
        if model.repoID == "local" || model.repoID.hasPrefix("/") {
            if model.repoID.hasPrefix("/") {
                return URL(fileURLWithPath: model.repoID, isDirectory: true)
            }
            if let f = model.files.first, f.path.hasPrefix("/") {
                return URL(fileURLWithPath: f.path).deletingLastPathComponent()
            }
        }
        return Paths.models.appendingPathComponent(Self.sanitize(model.repoID), isDirectory: true)
    }

    /// Files are stored under the model directory keeping their repo-relative path (or absolute path for custom local models).
    public func localURL(for file: ModelFile, in model: CatalogModel) -> URL {
        if file.path.hasPrefix("/") {
            return URL(fileURLWithPath: file.path)
        }
        return localDirectory(for: model).appendingPathComponent(file.path)
    }

    public func isDownloaded(_ model: CatalogModel) -> Bool {
        guard model.backend != .ollama, !model.files.isEmpty else { return false }
        return model.files.allSatisfy { f in
            let u = localURL(for: f, in: model)
            guard let size = (try? FileManager.default.attributesOfItem(atPath: u.path))?[.size] as? NSNumber else { return false }
            if let exp = f.sizeBytes { return size.int64Value == exp }
            return size.int64Value > 0
        }
    }

    public func download(_ model: CatalogModel, progress: @escaping @Sendable (DownloadProgress) -> Void) async throws -> URL {
        let dir = localDirectory(for: model)
        if model.backend == .ollama || model.files.isEmpty { return dir }   // setup engine runs `ollama pull`
        if isDownloaded(model) { return dir }                               // already on disk or custom local file

        // Disk space check (existing .part bytes count as already downloaded).
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        var needed: Int64 = 0
        for f in model.files {
            let part = localURL(for: f, in: model).appendingPathExtension("part")
            let have = ((try? fm.attributesOfItem(atPath: part.path))?[.size] as? NSNumber)?.int64Value ?? 0
            needed += max(0, (f.sizeBytes ?? 0) - have)
        }
        if let cap = (try? dir.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage,
           Int64(cap) < needed + 200_000_000 {
            throw OrbError.message("Not enough disk space: need \(Self.fmt(needed)), have \(Self.fmt(Int64(cap))).")
        }

        let grandTotal = model.files.map { $0.sizeBytes ?? 0 }.reduce(0, +)
        var doneBefore: Int64 = 0
        for f in model.files {
            try Task.checkCancellation()
            let offsetBase = doneBefore
            let dest = localURL(for: f, in: model)
            let size = try await fetch(repo: model.repoID, file: f, dest: dest) { done, total, bps in
                let overall = grandTotal > 0 ? grandTotal : total
                let d = offsetBase + done
                let remaining = max(0, overall - d)
                progress(DownloadProgress(fileName: (f.path as NSString).lastPathComponent, bytesDone: d, bytesTotal: max(overall, d),
                                          bytesPerSecond: bps, etaSeconds: bps > 1 ? Double(remaining) / bps : nil))
            }
            doneBefore += size
        }
        return dir
    }

    private func makeRequest(repo: String, path: String, rangeFrom: Int64) -> URLRequest {
        let encoded = path.split(separator: "/").map { $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0) }.joined(separator: "/")
        var req = URLRequest(url: URL(string: "https://huggingface.co/\(repo)/resolve/main/\(encoded)")!, timeoutInterval: 60)
        if let t = token { req.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization") }
        if rangeFrom > 0 { req.setValue("bytes=\(rangeFrom)-", forHTTPHeaderField: "Range") }
        return req
    }

    /// Downloads one file; returns its final size.
    private func fetch(repo: String, file: ModelFile, dest: URL,
                       report: @escaping (Int64, Int64, Double) -> Void) async throws -> Int64 {
        let fm = FileManager.default
        try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        let part = dest.appendingPathExtension("part")

        // Already complete?
        if let s = (try? fm.attributesOfItem(atPath: dest.path))?[.size] as? NSNumber,
           s.int64Value > 0, file.sizeBytes == nil || file.sizeBytes == s.int64Value {
            report(s.int64Value, s.int64Value, 0)
            return s.int64Value
        }

        var attempt = 0
        while true {
            do { return try await attemptFetch(repo: repo, file: file, dest: dest, part: part, report: report) }
            catch let e as URLError where e.code != .cancelled && attempt < 3 && !Task.isCancelled {
                attempt += 1
                try await Task.sleep(nanoseconds: UInt64(attempt) * 1_000_000_000)   // keep .part, resume
            }
        }
    }

    private func attemptFetch(repo: String, file: ModelFile, dest: URL, part: URL,
                              report: @escaping (Int64, Int64, Double) -> Void) async throws -> Int64 {
        let fm = FileManager.default
        var offset = ((try? fm.attributesOfItem(atPath: part.path))?[.size] as? NSNumber)?.int64Value ?? 0
        if let exp = file.sizeBytes, offset > exp { try? fm.removeItem(at: part); offset = 0 }

        var total = file.sizeBytes ?? 0
        if offset > 0 && offset == total {
            // fully downloaded, just needs verifying
        } else {
            let req = makeRequest(repo: repo, path: file.path, rangeFrom: offset)
            let (bytes, resp): (URLSession.AsyncBytes, URLResponse)
            do { (bytes, resp) = try await session.bytes(for: req) }
            catch let e as URLError where e.code == .cancelled { throw CancellationError() }
            guard let http = resp as? HTTPURLResponse else { throw OrbError.message("Bad response") }
            switch http.statusCode {
            case 206: break
            case 200: offset = 0; try? fm.removeItem(at: part)      // server ignored Range
            case 416: try? fm.removeItem(at: part); throw URLError(.cannotParseResponse)
            case 401, 403: throw OrbError.message("Access denied (HTTP \(http.statusCode)) for \(repo)/\(file.path). Set HF_TOKEN if the repo is gated.")
            case 404: throw OrbError.message("File not found on Hugging Face: \(repo)/\(file.path)")
            default: throw OrbError.message("HTTP \(http.statusCode) downloading \(file.path)")
            }
            if http.expectedContentLength > 0 { total = max(total, offset + http.expectedContentLength) }

            if !fm.fileExists(atPath: part.path) { fm.createFile(atPath: part.path, contents: nil) }
            let handle = try FileHandle(forWritingTo: part)
            defer { try? handle.close() }
            try handle.seekToEnd()

            var done = offset
            var buf = Data(); buf.reserveCapacity(1 << 20)
            let start = Date(); var lastReport = Date.distantPast
            let startBytes = offset
            do {
                for try await b in bytes {
                    buf.append(b)
                    if buf.count >= 1 << 20 {
                        try handle.write(contentsOf: buf); done += Int64(buf.count); buf.removeAll(keepingCapacity: true)
                        try Task.checkCancellation()
                        if Date().timeIntervalSince(lastReport) > 0.25 {
                            lastReport = Date()
                            report(done, total, Double(done - startBytes) / max(0.001, Date().timeIntervalSince(start)))
                        }
                    }
                }
            } catch {
                // keep partial progress on cancel/failure
                if !buf.isEmpty { try? handle.write(contentsOf: buf) }
                if error is CancellationError || (error as? URLError)?.code == .cancelled { throw CancellationError() }
                throw error
            }
            if !buf.isEmpty { try handle.write(contentsOf: buf); done += Int64(buf.count) }
            report(done, max(total, done), Double(done - startBytes) / max(0.001, Date().timeIntervalSince(start)))
        }

        let finalSize = ((try? fm.attributesOfItem(atPath: part.path))?[.size] as? NSNumber)?.int64Value ?? 0
        if let exp = file.sizeBytes, finalSize != exp {
            throw URLError(.networkConnectionLost)   // truncated; retry resumes
        }
        if let sha = file.sha256 {
            let actual = try Self.sha256(of: part)
            if actual.lowercased() != sha.lowercased() {
                try? fm.removeItem(at: part)
                throw OrbError.message("Checksum mismatch for \(file.path); partial file deleted, please retry.")
            }
        }
        try? fm.removeItem(at: dest)
        try fm.moveItem(at: part, to: dest)
        return finalSize
    }

    static func sha256(of url: URL) throws -> String {
        let h = try FileHandle(forReadingFrom: url)
        defer { try? h.close() }
        var hasher = SHA256()
        while let d = try h.read(upToCount: 4 << 20), !d.isEmpty { hasher.update(data: d) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func fmt(_ b: Int64) -> String { ByteCountFormatter.string(fromByteCount: b, countStyle: .file) }
}
