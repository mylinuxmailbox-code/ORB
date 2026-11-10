import Foundation

public enum VADEvent {
    case speechStart
    case speechEnd([Float])   // 16kHz mono samples incl. pre-roll
    case discarded            // speech started but was shorter than minimum
}

/// Energy-based VAD with adaptive noise floor, hysteresis, hangover and pre-roll.
public final class VoiceActivityDetector {
    public struct Config: Sendable {
        public var sampleRate = 16000
        public var frameMs = 20
        public var onRatio: Float = 3.0        // start threshold = floor * ratio
        public var offRatio: Float = 1.8       // stop threshold (hysteresis)
        public var minOn: Float = 0.015        // absolute minimum start RMS
        public var minOff: Float = 0.008
        public var startMs = 100               // sustained energy before speechStart
        public var hangoverMs = 700            // silence before speechEnd
        public var preRollMs = 300
        public var minSpeechMs = 250           // shorter utterances discarded
        public var maxUtteranceMs = 30_000
        public init() {}
    }
    public var config: Config
    private(set) public var noiseFloor: Float = 0.003
    private(set) public var inSpeech = false
    private var pending: [Float] = []
    private var preRoll: [[Float]] = []
    private var utterance: [Float] = []
    private var aboveCount = 0
    private var belowCount = 0
    private var voicedFrames = 0
    private var candidate: [[Float]] = []
    private var frameSize: Int { config.sampleRate * config.frameMs / 1000 }

    public init(config: Config = Config()) { self.config = config }

    public func reset() {
        pending = []; preRoll = []; utterance = []; candidate = []
        aboveCount = 0; belowCount = 0; voicedFrames = 0; inSpeech = false
    }

    public static func rms(_ s: [Float]) -> Float {
        guard !s.isEmpty else { return 0 }
        var sum: Float = 0
        for v in s { sum += v * v }
        return (sum / Float(s.count)).squareRoot()
    }

    public func process(_ samples: [Float]) -> [VADEvent] {
        pending.append(contentsOf: samples)
        var events: [VADEvent] = []
        let fs = frameSize
        var idx = 0
        while pending.count - idx >= fs {
            let frame = Array(pending[idx..<idx + fs])
            idx += fs
            step(frame, &events)
        }
        if idx > 0 { pending.removeFirst(idx) }
        return events
    }

    private func step(_ frame: [Float], _ events: inout [VADEvent]) {
        let e = Self.rms(frame)
        let on = max(noiseFloor * config.onRatio, config.minOn)
        let off = max(noiseFloor * config.offRatio, config.minOff)
        let startFrames = max(1, config.startMs / config.frameMs)
        let hangFrames = max(1, config.hangoverMs / config.frameMs)
        let preFrames = max(0, config.preRollMs / config.frameMs)

        if !inSpeech {
            if e > on {
                aboveCount += 1
                candidate.append(frame)
                if aboveCount >= startFrames {
                    inSpeech = true
                    utterance = preRoll.flatMap { $0 } + candidate.flatMap { $0 }
                    voicedFrames = candidate.count
                    belowCount = 0
                    preRoll = []; candidate = []; aboveCount = 0
                    events.append(.speechStart)
                }
            } else {
                // not speech: adapt noise floor (fast down, slow up), flush candidate to pre-roll
                if !candidate.isEmpty { preRoll.append(contentsOf: candidate); candidate = []; aboveCount = 0 }
                let a: Float = e < noiseFloor ? 0.2 : 0.02
                noiseFloor += a * (e - noiseFloor)
                noiseFloor = min(max(noiseFloor, 0.0005), 0.05)
                preRoll.append(frame)
                if preRoll.count > preFrames { preRoll.removeFirst(preRoll.count - preFrames) }
            }
        } else {
            utterance.append(contentsOf: frame)
            if e > off { voicedFrames += 1; belowCount = 0 } else { belowCount += 1 }
            let tooLong = utterance.count > config.maxUtteranceMs * config.sampleRate / 1000
            if belowCount >= hangFrames || tooLong {
                let voicedMs = voicedFrames * config.frameMs
                let out = utterance
                inSpeech = false; utterance = []; belowCount = 0; voicedFrames = 0
                events.append(voicedMs >= config.minSpeechMs ? .speechEnd(out) : .discarded)
            }
        }
    }
}

public enum WAV {
    /// Float samples [-1,1] → 16-bit PCM mono WAV.
    public static func encode(samples: [Float], sampleRate: Int = 16000) -> Data {
        var d = Data()
        func u32(_ v: UInt32) { var x = v.littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { var x = v.littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        let dataBytes = UInt32(samples.count * 2)
        d.append("RIFF".data(using: .ascii)!); u32(36 + dataBytes)
        d.append("WAVE".data(using: .ascii)!)
        d.append("fmt ".data(using: .ascii)!); u32(16); u16(1); u16(1)
        u32(UInt32(sampleRate)); u32(UInt32(sampleRate * 2)); u16(2); u16(16)
        d.append("data".data(using: .ascii)!); u32(dataBytes)
        var pcm = [Int16](); pcm.reserveCapacity(samples.count)
        for s in samples { pcm.append(Int16(max(-1, min(1, s)) * 32767).littleEndian) }
        pcm.withUnsafeBytes { d.append(contentsOf: $0) }
        return d
    }

    public static func tone(frequency: Double = 440, seconds: Double = 0.6, sampleRate: Int = 24000, amplitude: Float = 0.3) -> Data {
        let n = Int(seconds * Double(sampleRate))
        var s = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let t = Double(i) / Double(sampleRate)
            let env = Float(min(1, min(t / 0.03, (seconds - t) / 0.05)))
            s[i] = amplitude * env * Float(sin(2 * .pi * frequency * t))
        }
        return encode(samples: s, sampleRate: sampleRate)
    }
}

/// Splits streaming text into speakable sentences.
public struct SentenceChunker {
    public var minLength = 12
    private var buffer = ""
    public init() {}

    public mutating func push(_ delta: String) -> [String] {
        buffer += delta
        var out: [String] = []
        let chars = Array(buffer)
        var start = 0
        var i = 0
        while i < chars.count {
            let c = chars[i]
            var boundary = false
            if c == "\n" { boundary = true }
            else if ".!?…。！？".contains(c) {
                if i + 1 < chars.count {
                    var j = i + 1
                    while j < chars.count, "\"')”’".contains(chars[j]) { j += 1 }
                    if j < chars.count, chars[j].isWhitespace { boundary = true; i = j - 1 }
                    else if j >= chars.count { boundary = false }
                }
            }
            if boundary {
                let s = String(chars[start...i]).trimmingCharacters(in: .whitespacesAndNewlines)
                if s.count >= minLength || c == "\n" && !s.isEmpty {
                    out.append(s); start = i + 1
                }
            }
            i += 1
        }
        buffer = String(chars[start...])
        return out
    }

    public mutating func flush() -> String? {
        let s = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        buffer = ""
        return s.isEmpty ? nil : s
    }
}
