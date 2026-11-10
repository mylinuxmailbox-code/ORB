import Foundation
import Combine

public struct ConversationTurn: Identifiable, Hashable, Sendable {
    public enum Role: String, Sendable { case user, assistant }
    public let id: UUID
    public var role: Role
    public var text: String
    public var date: Date
    public init(id: UUID = UUID(), role: Role, text: String, date: Date = Date()) {
        self.id = id; self.role = role; self.text = text; self.date = date
    }
}

@MainActor
public final class VoiceAgent: ObservableObject {
    @Published public private(set) var state: OrbState = .idle
    @Published public private(set) var level: Float = 0
    @Published public private(set) var transcript: [ConversationTurn] = []
    @Published public private(set) var lastError: String?
    @Published public private(set) var llmTag: String

    public private(set) var config: OrbConfig
    public var stt: STTClient
    public var llm: LLMClient
    public var tts: TTSClient
    public var maxHistoryMessages = 20

    private let audio: AudioIO
    private var history: [ChatMessage] = []
    private var running = false
    private var micTask: Task<Void, Never>?
    private var turnTask: Task<Void, Never>?
    private var meterTask: Task<Void, Never>?
    private var turnID = 0

    private let vad = VoiceActivityDetector()
    private let bargeVAD: VoiceActivityDetector
    private var usingBarge = false

    public init(config: OrbConfig, stt: STTClient = WhisperHTTPClient(), llm: LLMClient = OllamaClient(),
                tts: TTSClient = PiperHTTPClient()) {
        self.config = config; self.stt = stt; self.llm = llm; self.tts = tts
        self.llmTag = config.llm.repoID
        self.audio = AudioIO(inputDeviceUID: config.inputDeviceUID, outputDeviceUID: config.outputDeviceUID)
        var b = VoiceActivityDetector.Config()
        b.onRatio = 5; b.minOn = 0.04; b.startMs = 260; b.offRatio = 2.5; b.minOff = 0.015
        bargeVAD = VoiceActivityDetector(config: b)
    }

    public var isRunning: Bool { running }

    // MARK: lifecycle
    /// Begins listening. Must be called explicitly by the user action; nothing records before this.
    public func start() async {
        guard !running else { return }
        guard await AudioIO.requestMicrophonePermission() else {
            fail("Microphone access is denied. Enable it in System Settings → Privacy & Security → Microphone.")
            return
        }
        do {
            let stream = try audio.startCapture(voiceProcessing: true)
            running = true; lastError = nil; state = .listening
            vad.reset(); bargeVAD.reset(); usingBarge = false
            micTask = Task { [weak self] in
                for await chunk in stream {
                    guard let self else { return }
                    self.handle(chunk)
                }
            }
            meterTask = Task { [weak self] in
                while !Task.isCancelled {
                    guard let self else { return }
                    let speaking = self.state == .speaking
                    let raw = speaking ? self.audio.outputLevel : self.audio.inputLevel
                    self.level = min(1, raw * 4)
                    try? await Task.sleep(nanoseconds: 33_000_000)
                }
            }
        } catch {
            fail(error.localizedDescription)
        }
    }

    public func stop() {
        running = false
        micTask?.cancel(); micTask = nil
        meterTask?.cancel(); meterTask = nil
        cancelTurn()
        audio.stopCapture()
        level = 0
        state = .idle
    }

    /// Cancels the current response (LLM, TTS queue, playback).
    public func interrupt() {
        cancelTurn()
        if running { state = .listening }
    }

    public func clearHistory() {
        history.removeAll(); transcript.removeAll()
    }

    public func switchModel(_ tag: String) {
        llmTag = tag
        config.llm.repoID = tag
    }

    public func updateSTT(_ model: CatalogModel) {
        config.stt = model
    }

    public func updateTTS(_ model: CatalogModel) {
        config.tts = model
    }

    public func sendText(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        cancelTurn()
        beginTurn { [weak self] in try await self?.runTurn(userText: t) }
    }

    // MARK: audio input
    private func handle(_ chunk: [Float]) {
        guard running else { return }
        let busy = state == .thinking || state == .speaking
        let det: VoiceActivityDetector
        if usingBarge { det = bargeVAD } else if busy { det = bargeVAD } else { det = vad }
        if det === bargeVAD && !busy && !usingBarge { bargeVAD.reset() }
        for ev in det.process(chunk) {
            switch ev {
            case .speechStart:
                if det === bargeVAD { usingBarge = true; interrupt() }
                state = .listening
            case .speechEnd(let samples):
                usingBarge = false
                let wav = WAV.encode(samples: samples)
                cancelTurn()
                state = .thinking
                beginTurn { [weak self] in try await self?.runTurn(wav: wav) }
            case .discarded:
                usingBarge = false
                if state == .listening || state == .error { state = .listening }
            }
        }
    }

    // MARK: turn pipeline
    private func cancelTurn() {
        turnTask?.cancel(); turnTask = nil
        turnID += 1
        audio.stop()
    }

    private func beginTurn(_ body: @escaping @MainActor () async throws -> Void) {
        let id = turnID
        turnTask = Task { [weak self] in
            do { try await body() }
            catch is CancellationError {}
            catch { if let self, self.turnID == id { self.fail(error.localizedDescription) } }
            if let self, self.turnID == id, self.running, self.state != .error { self.state = .listening }
        }
    }

    private var sttLanguage: String {
        let l = config.stt.languages
        if l.count == 1, let f = l.first, f != "multilingual" { return f }
        return "auto"
    }

    private func runTurn(wav: Data) async throws {
        state = .thinking
        let text = try await stt.transcribe(wav: wav, language: sttLanguage)
        try Task.checkCancellation()
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = cleaned.lowercased()
        if cleaned.isEmpty || (lower.hasPrefix("[") && lower.hasSuffix("]")) || (lower.hasPrefix("(") && lower.hasSuffix(")")) { return }
        try await runTurn(userText: cleaned)
    }

    private func runTurn(userText: String) async throws {
        state = .thinking
        transcript.append(ConversationTurn(role: .user, text: userText))
        history.append(ChatMessage(role: "user", content: userText))
        if history.count > maxHistoryMessages { history.removeFirst(history.count - maxHistoryMessages) }
        var messages = [ChatMessage(role: "system", content: config.systemPrompt)]
        messages += history

        let reply = ConversationTurn(role: .assistant, text: "")
        transcript.append(reply)
        let replyID = reply.id
        var full = ""

        let tts = self.tts, audio = self.audio
        let (queue, qcont) = AsyncStream.makeStream(of: Task<Data, Error>.self)
        var synths: [Task<Data, Error>] = []
        let player = Task { [weak self] in
            var firstError: Error?
            for await t in queue {
                if Task.isCancelled { break }
                do {
                    let data = try await t.value
                    if Task.isCancelled { break }
                    await MainActor.run { if let s = self, s.running, s.state != .error { s.state = .speaking } }
                    try await audio.play(wav: data)
                } catch is CancellationError { break }
                catch { firstError = firstError ?? error }
            }
            if let e = firstError, !Task.isCancelled {
                await MainActor.run { self?.fail("Speech output failed: \(e.localizedDescription)") }
            }
        }
        func enqueue(_ s: String) {
            let spoken = Self.speakable(s)
            guard !spoken.isEmpty else { return }
            let t = Task { try await tts.synthesize(text: spoken) }
            synths.append(t); qcont.yield(t)
        }

        var chunker = SentenceChunker()
        var failure: Error?
        await withTaskCancellationHandler {
            do {
                for try await delta in llm.stream(model: llmTag, messages: messages) {
                    try Task.checkCancellation()
                    full += delta
                    if let i = transcript.firstIndex(where: { $0.id == replyID }) { transcript[i].text = full }
                    for s in chunker.push(delta) { enqueue(s) }
                }
                if let rest = chunker.flush() { enqueue(rest) }
            } catch { failure = error }
            qcont.finish()
            await player.value
        } onCancel: {
            player.cancel(); qcont.finish(); audio.stop()
        }
        if Task.isCancelled || failure is CancellationError { synths.forEach { $0.cancel() } }
        if !full.isEmpty {
            history.append(ChatMessage(role: "assistant", content: full))
        } else if let i = transcript.firstIndex(where: { $0.id == replyID }) {
            transcript.remove(at: i)
        }
        if let f = failure, !(f is CancellationError) { throw f }
        try Task.checkCancellation()
    }

    nonisolated static func speakable(_ s: String) -> String {
        var t = s
        for ch in ["*", "#", "`", "_", "~"] { t = t.replacingOccurrences(of: ch, with: "") }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func fail(_ message: String) {
        lastError = message
        state = .error
    }
}
