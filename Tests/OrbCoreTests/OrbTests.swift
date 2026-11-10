import Testing
@testable import OrbCore

@Suite struct OrbTests {
    @Test func testEveryStateRendersNonEmptyGrid() {
        let e = OrbEngine(width: 60, height: 30)
        for s in OrbState.allCases {
            for i in 0..<30 { e.render(state: s, time: Double(i) / 24, amplitude: 0.5) }
            #expect(e.pixels.count == 60 * 30)
            let lit = e.pixels.filter { $0.a > 0.2 }.count
            #expect(lit > 50)
            #expect(e.pixels.allSatisfy { $0.a >= 0 && $0.a <= 1 && $0.r <= 1 })
        }
    }

    @Test func testDeterministic() {
        func run() -> [OrbPixel] {
            let e = OrbEngine(width: 40, height: 20)
            for i in 0..<20 { e.render(state: .downloading, time: Double(i) / 24, amplitude: 0.3) }
            return e.pixels
        }
        #expect(run() == run())
    }

    @Test func testAmplitudeChangesListening() {
        let a = OrbEngine(width: 40, height: 20), b = OrbEngine(width: 40, height: 20)
        for i in 0..<40 {
            a.render(state: .listening, time: Double(i) / 24, amplitude: 0)
            b.render(state: .listening, time: Double(i) / 24, amplitude: 1)
        }
        #expect(a.pixels != b.pixels)
    }

    @Test func testTerminalFrameDimensions() {
        let e = OrbEngine(width: 50, height: 24)
        let r = TerminalOrbRenderer(useColor: false)
        e.render(state: .ready, time: 1, amplitude: 0)
        let s = r.renderString(grid: e.pixels, cols: 50, rows: 12)
        let lines = s.split(separator: "\n", omittingEmptySubsequences: false)
        #expect(lines.count == 12)
        #expect(lines.allSatisfy { $0.count == 50 })
        #expect(s.contains { $0 != " " && $0 != "\n" })
    }

    @Test func testColorFrameAndDiff() {
        let e = OrbEngine(width: 40, height: 20)
        let r = TerminalOrbRenderer(useColor: true)
        e.render(state: .idle, time: 0, amplitude: 0)
        let full = r.renderDiff(grid: e.pixels, cols: 40, rows: 10, footer: ["hello"])
        #expect(full.contains("▀"))
        #expect(full.contains("38;2;"))
        e.render(state: .idle, time: 0.04, amplitude: 0)
        let d1 = r.renderDiff(grid: e.pixels, cols: 40, rows: 10, footer: ["hello"])
        #expect(d1.count < full.count)
        let same = r.renderDiff(grid: e.pixels, cols: 40, rows: 10, footer: ["hello"])
        #expect(same.isEmpty)
    }
}
