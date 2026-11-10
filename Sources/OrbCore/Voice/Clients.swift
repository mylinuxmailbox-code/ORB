import Foundation

private func loopbackSession() -> URLSession {
    let c = URLSessionConfiguration.ephemeral
    c.timeoutIntervalForRequest = 120
    c.waitsForConnectivity = false
    c.connectionProxyDictionary = [:]   // never go through a proxy; loopback only
    return URLSession(configuration: c)
}

/// whisper.cpp `whisper-server` client.
public struct WhisperHTTPClient: STTClient {
    public var baseURL: URL
    public init(baseURL: URL = Endpoints.whisper) { self.baseURL = baseURL }

    public func transcribe(wav: Data, language: String?) async throws -> String {
        let boundary = "orb-" + UUID().uuidString
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".data(using: .utf8)!)
        }
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\nContent-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(wav)
        body.append("\r\n".data(using: .utf8)!)
        field("response_format", "json")
        field("temperature", "0")
        field("language", language ?? "auto")
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        var req = URLRequest(url: baseURL.appendingPathComponent("inference"))
        req.httpMethod = "POST"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        let (data, resp) = try await loopbackSession().data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            throw OrbError.message("Speech recognition failed (HTTP \((resp as? HTTPURLResponse)?.statusCode ?? -1)): \(String(data: data, encoding: .utf8) ?? "")")
        }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw OrbError.message("Unexpected response from speech recognizer")
        }
        if let err = obj["error"] as? String { throw OrbError.message(err) }
        return ((obj["text"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Ollama chat client (streaming ndjson).
public struct OllamaClient: LLMClient {
    public var baseURL: URL
    public init(baseURL: URL = Endpoints.ollama) { self.baseURL = baseURL }

    public func stream(model: String, messages: [ChatMessage]) -> AsyncThrowingStream<String, Error> {
        let base = baseURL
        return AsyncThrowingStream { cont in
            let task = Task {
                do {
                    var req = URLRequest(url: base.appendingPathComponent("api/chat"))
                    req.httpMethod = "POST"
                    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    let payload: [String: Any] = [
                        "model": model, "stream": true,
                        "messages": messages.map { ["role": $0.role, "content": $0.content] },
                    ]
                    req.httpBody = try JSONSerialization.data(withJSONObject: payload)
                    let (bytes, resp) = try await loopbackSession().bytes(for: req)
                    guard let http = resp as? HTTPURLResponse else { throw OrbError.message("No response from Ollama") }
                    if http.statusCode != 200 {
                        var text = ""
                        for try await line in bytes.lines { text += line }
                        throw OrbError.message("Ollama error (HTTP \(http.statusCode)): \(text)")
                    }
                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        guard !line.isEmpty, let d = line.data(using: .utf8),
                              let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { continue }
                        if let err = obj["error"] as? String { throw OrbError.message(err) }
                        if let m = obj["message"] as? [String: Any], let c = m["content"] as? String, !c.isEmpty {
                            cont.yield(c)
                        }
                        if (obj["done"] as? Bool) == true { break }
                    }
                    cont.finish()
                } catch is CancellationError {
                    cont.finish(throwing: CancellationError())
                } catch {
                    cont.finish(throwing: error)
                }
            }
            cont.onTermination = { _ in task.cancel() }
        }
    }

    /// Installed model tags.
    public func listModels() async throws -> [String] {
        let (data, resp) = try await loopbackSession().data(from: baseURL.appendingPathComponent("api/tags"))
        guard (resp as? HTTPURLResponse)?.statusCode == 200,
              let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = obj["models"] as? [[String: Any]] else {
            throw OrbError.message("Could not list Ollama models")
        }
        return models.compactMap { $0["name"] as? String }
    }
}

/// Piper TTS server client.
public struct PiperHTTPClient: TTSClient {
    public var baseURL: URL
    public init(baseURL: URL = Endpoints.tts) { self.baseURL = baseURL }

    public func synthesize(text: String) async throws -> Data {
        var req = URLRequest(url: baseURL.appendingPathComponent("tts"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["text": text])
        let (data, resp) = try await loopbackSession().data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200, data.count > 44 else {
            throw OrbError.message("Speech synthesis failed (HTTP \((resp as? HTTPURLResponse)?.statusCode ?? -1))")
        }
        return data
    }
}
