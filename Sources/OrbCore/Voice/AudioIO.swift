import Foundation
import AVFoundation
import AudioToolbox
import CoreAudio

/// Mic capture (16kHz mono Float32) + WAV playback on a shared AVAudioEngine.
public final class AudioIO: @unchecked Sendable {
    public static let captureSampleRate: Double = 16000
    private let playFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24000, channels: 1, interleaved: false)!

    private let lock = NSLock()
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var captureCont: AsyncStream<[Float]>.Continuation?
    private var _inLevel: Float = 0
    private var _outLevel: Float = 0
    private var playToken: PlayToken?
    public private(set) var voiceProcessingActive = false

    public var inputDeviceUID: String?
    public var outputDeviceUID: String?

    public init(inputDeviceUID: String? = nil, outputDeviceUID: String? = nil) {
        self.inputDeviceUID = inputDeviceUID; self.outputDeviceUID = outputDeviceUID
    }

    public var inputLevel: Float { lock.lock(); defer { lock.unlock() }; return _inLevel }
    public var outputLevel: Float { lock.lock(); defer { lock.unlock() }; return _outLevel }

    // MARK: permission
    public static var microphoneAuthorized: Bool { AVCaptureDevice.authorizationStatus(for: .audio) == .authorized }
    public static func requestMicrophonePermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    // MARK: engine
    private final class PlayToken: @unchecked Sendable {
        private let l = NSLock(); private var cont: CheckedContinuation<Void, Never>?; private var done = false
        func set(_ c: CheckedContinuation<Void, Never>) { l.lock(); if done { l.unlock(); c.resume() } else { cont = c; l.unlock() } }
        func finish() { l.lock(); done = true; let c = cont; cont = nil; l.unlock(); c?.resume() }
    }

    private static func setDevice(_ unit: AudioUnit?, uid: String?) {
        guard let unit, let uid, var dev = AudioDevices.deviceID(forUID: uid) else { return }
        AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                             &dev, UInt32(MemoryLayout<AudioDeviceID>.size))
    }

    private func buildEngine(capture: Bool, voiceProcessing: Bool) throws {
        teardown()
        let eng = AVAudioEngine()
        var vp = false
        if capture {
            let input = eng.inputNode
            if voiceProcessing && inputDeviceUID == nil && outputDeviceUID == nil {
                do { try input.setVoiceProcessingEnabled(true); vp = true } catch { vp = false }
            }
            if !vp { Self.setDevice(input.audioUnit, uid: inputDeviceUID) }
        }
        if !vp { Self.setDevice(eng.outputNode.audioUnit, uid: outputDeviceUID) }
        let node = AVAudioPlayerNode()
        eng.attach(node)
        eng.connect(node, to: eng.mainMixerNode, format: playFormat)
        node.installTap(onBus: 0, bufferSize: 1024, format: playFormat) { [weak self] buf, _ in
            guard let self, let ch = buf.floatChannelData?[0] else { return }
            let n = Int(buf.frameLength); var sum: Float = 0
            for i in 0..<n { sum += ch[i] * ch[i] }
            let r = n > 0 ? (sum / Float(n)).squareRoot() : 0
            self.lock.lock(); self._outLevel = r; self.lock.unlock()
        }
        if capture { try installCaptureTap(eng) }
        eng.prepare()
        try eng.start()
        lock.lock(); engine = eng; player = node; voiceProcessingActive = vp; lock.unlock()
    }

    private func installCaptureTap(_ eng: AVAudioEngine) throws {
        let input = eng.inputNode
        let inFormat = input.outputFormat(forBus: 0)
        guard inFormat.sampleRate > 0, inFormat.channelCount > 0 else { throw OrbError.message("No audio input device available") }
        let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Self.captureSampleRate, channels: 1, interleaved: false)!
        guard let conv = AVAudioConverter(from: inFormat, to: outFormat) else { throw OrbError.message("Cannot convert microphone format") }
        input.installTap(onBus: 0, bufferSize: 2048, format: inFormat) { [weak self] buf, _ in
            guard let self else { return }
            let cap = AVAudioFrameCount(Double(buf.frameLength) * Self.captureSampleRate / inFormat.sampleRate) + 32
            guard let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: cap) else { return }
            var supplied = false
            var err: NSError?
            conv.convert(to: out, error: &err) { _, status in
                if supplied { status.pointee = .noDataNow; return nil }
                supplied = true; status.pointee = .haveData; return buf
            }
            guard err == nil, let ch = out.floatChannelData?[0], out.frameLength > 0 else { return }
            let samples = Array(UnsafeBufferPointer(start: ch, count: Int(out.frameLength)))
            let r = VoiceActivityDetector.rms(samples)
            self.lock.lock(); self._inLevel = r; let c = self.captureCont; self.lock.unlock()
            c?.yield(samples)
        }
    }

    /// Starts the microphone. Only call after the user explicitly started the agent.
    public func startCapture(voiceProcessing: Bool = true) throws -> AsyncStream<[Float]> {
        let (stream, cont) = AsyncStream.makeStream(of: [Float].self, bufferingPolicy: .bufferingNewest(256))
        lock.lock(); captureCont?.finish(); captureCont = cont; lock.unlock()
        do { try buildEngine(capture: true, voiceProcessing: voiceProcessing) }
        catch {
            if voiceProcessing { try buildEngine(capture: true, voiceProcessing: false) } else { throw error }
        }
        return stream
    }

    public func stopCapture() { teardown() }

    private func teardown() {
        lock.lock()
        let eng = engine, p = player, tok = playToken, c = captureCont
        engine = nil; player = nil; playToken = nil; captureCont = nil; _inLevel = 0; _outLevel = 0
        lock.unlock()
        p?.stop(); p?.removeTap(onBus: 0)
        if let eng {
            if eng.isRunning { eng.inputNode.removeTap(onBus: 0) }
            eng.stop()
        }
        tok?.finish(); c?.finish()
    }

    // MARK: playback
    /// Plays WAV data; returns when finished or stopped.
    public func play(wav: Data) async throws {
        let buffer = try Self.decode(wav: wav, to: playFormat)
        let (node, token) = try preparePlayback()
        node.scheduleBuffer(buffer, at: nil, options: [], completionCallbackType: .dataPlayedBack) { _ in token.finish() }
        if !node.isPlaying { node.play() }
        await withTaskCancellationHandler {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in token.set(c) }
        } onCancel: { [weak self] in self?.stop() }
        resetOutLevel()
    }

    private func resetOutLevel() { lock.lock(); _outLevel = 0; lock.unlock() }

    private func preparePlayback() throws -> (AVAudioPlayerNode, PlayToken) {
        lock.lock(); let have = engine != nil; lock.unlock()
        if !have { try buildEngine(capture: false, voiceProcessing: false) }
        lock.lock(); defer { lock.unlock() }
        guard let node = player else { throw OrbError.message("Audio engine unavailable") }
        let token = PlayToken(); playToken = token
        return (node, token)
    }

    /// Immediately stops playback (barge-in). Capture keeps running.
    public func stop() {
        lock.lock(); let p = player; let tok = playToken; lock.unlock()
        p?.stop()
        tok?.finish()
        lock.lock(); _outLevel = 0; lock.unlock()
    }

    static func decode(wav: Data, to format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("orb-\(UUID().uuidString).wav")
        try wav.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let file = try AVAudioFile(forReading: url)
        guard let src = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw OrbError.message("Cannot allocate audio buffer")
        }
        try file.read(into: src)
        if src.format.sampleRate == format.sampleRate && src.format.channelCount == format.channelCount { return src }
        guard let conv = AVAudioConverter(from: src.format, to: format) else { throw OrbError.message("Unsupported audio format") }
        let cap = AVAudioFrameCount(Double(src.frameLength) * format.sampleRate / src.format.sampleRate) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: cap) else { throw OrbError.message("Cannot allocate audio buffer") }
        var supplied = false; var err: NSError?
        conv.convert(to: out, error: &err) { _, status in
            if supplied { status.pointee = .endOfStream; return nil }
            supplied = true; status.pointee = .haveData; return src
        }
        if let err { throw err }
        return out
    }

    // MARK: tests
    /// Records `seconds` from the mic and returns the peak absolute sample level (0...1).
    public static func testMicrophone(deviceUID: String?, seconds: Double = 2) async throws -> Float {
        guard await requestMicrophonePermission() else { throw OrbError.message("Microphone permission denied") }
        let io = AudioIO(inputDeviceUID: deviceUID)
        let stream = try io.startCapture(voiceProcessing: false)
        defer { io.stopCapture() }
        let target = Int(seconds * captureSampleRate)
        var count = 0; var peak: Float = 0
        for await chunk in stream {
            for s in chunk { peak = max(peak, abs(s)) }
            count += chunk.count
            if count >= target { break }
        }
        return peak
    }

    /// Plays a short tone on the given output device.
    public static func testSpeaker(deviceUID: String?) async throws {
        let io = AudioIO(outputDeviceUID: deviceUID)
        defer { io.stopCapture() }
        try await io.play(wav: WAV.tone(frequency: 523, seconds: 0.5))
        try await io.play(wav: WAV.tone(frequency: 659, seconds: 0.5))
    }
}
