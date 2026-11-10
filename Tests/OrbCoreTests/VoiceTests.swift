import Foundation
import Testing
@testable import OrbCore

@Suite struct VoiceTests {
    private func noise(_ n: Int, amp: Float) -> [Float] { (0..<n).map { _ in Float.random(in: -amp...amp) } }
    private func sine(_ n: Int, amp: Float) -> [Float] { (0..<n).map { amp * sin(Float($0) * 0.2) } }

    @Test func testVADDetectsSpeechBurst() {
        let vad = VoiceActivityDetector()
        var events: [VADEvent] = []
        events += vad.process(noise(16000, amp: 0.003))
        events += vad.process(sine(16000, amp: 0.3))
        events += vad.process(noise(16000, amp: 0.003))
        var started = false; var ended: [Float]?
        for e in events {
            if case .speechStart = e { started = true }
            if case .speechEnd(let s) = e { ended = s }
        }
        #expect(started)
        #expect(ended != nil)
        #expect((ended?.count ?? 0) > 16000)
    }

    @Test func testVADIgnoresSilenceAndShortClick() {
        let vad = VoiceActivityDetector()
        var events = vad.process(noise(32000, amp: 0.003))
        events += vad.process(sine(1600, amp: 0.3))   // 100ms blip
        events += vad.process(noise(32000, amp: 0.003))
        for e in events { if case .speechEnd = e { Issue.record("should not end speech") } }
    }

    @Test func testBargeInNeedsSustainedSpeech() {
        var c = VoiceActivityDetector.Config(); c.startMs = 260
        let vad = VoiceActivityDetector(config: c)
        _ = vad.process(noise(8000, amp: 0.003))
        var ev = vad.process(sine(2400, amp: 0.3))   // 150ms
        #expect(ev.isEmpty)
        ev = vad.process(sine(3200, amp: 0.3))
        #expect(ev.contains { if case .speechStart = $0 { return true }; return false })
    }

    @Test func testWAVHeader() {
        let d = WAV.encode(samples: [0, 0.5, -0.5, 1], sampleRate: 16000)
        #expect(d.count == 44 + 8)
        #expect(String(data: d.prefix(4), encoding: .ascii) == "RIFF")
        #expect(String(data: d[8..<12], encoding: .ascii) == "WAVE")
    }

    @Test func testSentenceChunker() {
        var c = SentenceChunker()
        var out = c.push("Hello there, friend. The value is 3.5 today! And")
        out += c.push(" more text")
        #expect(out == ["Hello there, friend.", "The value is 3.5 today!"])
        #expect(c.flush() == "And more text")
    }
}
