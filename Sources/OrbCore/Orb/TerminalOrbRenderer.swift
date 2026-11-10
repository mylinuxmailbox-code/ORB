import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Converts an `OrbPixel` grid to ANSI output (half-blocks, truecolor) with differential updates.
/// Grid height is 2x the number of text rows.
public final class TerminalOrbRenderer {
    public let useColor: Bool
    private struct Cell: Equatable { var ch: Character = " "; var fg: UInt32 = 0; var bg: UInt32 = 0 }
    private var prev: [Cell] = []
    private var prevCols = 0, prevRows = 0
    private var prevFooter: [String] = []
    private static let ramp: [Character] = [" ", "·", ".", ":", "+", "*", "o", "O"]
    private static let ascii: [Character] = Array(" .:-=+*#%@")

    public init(useColor: Bool? = nil) {
        self.useColor = useColor ?? (ProcessInfo.processInfo.environment["NO_COLOR"] == nil)
    }

    public func invalidate() { prev = []; prevFooter = [] }

    @inline(__always) private static func pack(_ p: OrbPixel) -> UInt32 {
        // premultiply with intensity, quantise to 5 bits-ish steps (fewer spurious diffs)
        let a = p.a
        func q(_ v: Float) -> UInt32 { UInt32(max(0, min(255, v * a * 255)) / 4) * 4 }
        return q(p.r) << 16 | q(p.g) << 8 | q(p.b)
    }

    private func cells(grid: [OrbPixel], cols: Int, rows: Int) -> [Cell] {
        var out = [Cell](repeating: Cell(), count: cols * rows)
        for row in 0..<rows {
            for c in 0..<cols {
                let top = grid[(row * 2) * cols + c], bot = grid[(row * 2 + 1) * cols + c]
                var cell = Cell()
                if useColor {
                    let m = max(top.a, bot.a)
                    if m < 0.22 {
                        // glow / particle: density character
                        let idx = min(Self.ramp.count - 1, Int(m * 4.5 * Float(Self.ramp.count - 1) / 1.0 * 0.5 + 0.5))
                        let hi = top.a >= bot.a ? top : bot
                        cell.ch = Self.ramp[idx]
                        var boosted = hi; boosted.a = min(1, hi.a * 3.2)
                        cell.fg = idx == 0 ? 0 : Self.pack(boosted)
                    } else {
                        cell.ch = "▀"; cell.fg = Self.pack(top); cell.bg = Self.pack(bot)
                    }
                } else {
                    let v = (top.a + bot.a) * 0.5
                    cell.ch = Self.ascii[min(Self.ascii.count - 1, Int(v * Float(Self.ascii.count - 1) + 0.5))]
                }
                out[row * cols + c] = cell
            }
        }
        return out
    }

    /// Full-frame plain string (no cursor addressing), rows joined by "\n". Used for non-TTY and tests.
    public func renderString(grid: [OrbPixel], cols: Int, rows: Int) -> String {
        let cs = cells(grid: grid, cols: cols, rows: rows)
        var s = ""
        for r in 0..<rows {
            var lastFG: UInt32 = .max, lastBG: UInt32 = .max
            for c in 0..<cols {
                let cell = cs[r * cols + c]
                if useColor { Self.emitColors(&s, cell, &lastFG, &lastBG) }
                s.append(cell.ch)
            }
            if useColor { s += "\u{1B}[0m" }
            if r < rows - 1 { s += "\n" }
        }
        return s
    }

    private static func emitColors(_ s: inout String, _ cell: Cell, _ lastFG: inout UInt32, _ lastBG: inout UInt32) {
        if cell.fg != lastFG { s += "\u{1B}[38;2;\(cell.fg >> 16);\((cell.fg >> 8) & 255);\(cell.fg & 255)m"; lastFG = cell.fg }
        if cell.bg != lastBG { s += "\u{1B}[48;2;\(cell.bg >> 16);\((cell.bg >> 8) & 255);\(cell.bg & 255)m"; lastBG = cell.bg }
    }

    /// Differential frame: only changed cells (and footer lines) are emitted. Rows start at screen row 1.
    /// `footer` lines are drawn below the orb rows.
    public func renderDiff(grid: [OrbPixel], cols: Int, rows: Int, footer: [String] = []) -> String {
        let cs = cells(grid: grid, cols: cols, rows: rows)
        var s = ""
        let full = prev.count != cs.count || prevCols != cols || prevRows != rows
        if full { s += "\u{1B}[0m\u{1B}[2J"; prevFooter = [] }
        for r in 0..<rows {
            var c = 0
            while c < cols {
                let i = r * cols + c
                if !full && prev[i] == cs[i] { c += 1; continue }
                s += "\u{1B}[\(r + 1);\(c + 1)H"
                var lastFG: UInt32 = .max, lastBG: UInt32 = .max
                // run of changed cells
                var j = c
                var gap = 0
                while j < cols {
                    let k = r * cols + j
                    if !full && prev[k] == cs[k] { gap += 1; if gap > 3 { break } } else { gap = 0 }
                    if useColor { Self.emitColors(&s, cs[k], &lastFG, &lastBG) }
                    s.append(cs[k].ch)
                    j += 1
                }
                if useColor { s += "\u{1B}[0m" }
                c = j
            }
        }
        for (i, line) in footer.enumerated() where full || i >= prevFooter.count || prevFooter[i] != line {
            s += "\u{1B}[\(rows + i + 1);1H\u{1B}[0m\u{1B}[2K" + Self.clip(line, cols)
        }
        if footer.count < prevFooter.count {
            for i in footer.count..<prevFooter.count { s += "\u{1B}[\(rows + i + 1);1H\u{1B}[2K" }
        }
        prev = cs; prevCols = cols; prevRows = rows; prevFooter = footer
        return s
    }

    /// Clip to visible width, ignoring ANSI escape sequences.
    static func clip(_ line: String, _ width: Int) -> String {
        var out = "", vis = 0, inEsc = false, sawEsc = false
        for ch in line {
            if inEsc { out.append(ch); if ch.isLetter { inEsc = false }; continue }
            if ch == "\u{1B}" { inEsc = true; sawEsc = true; out.append(ch); continue }
            if vis >= width { break }
            out.append(ch); vis += 1
        }
        return sawEsc ? out + "\u{1B}[0m" : out
    }
}

/// Owns the terminal: alt screen, raw keys, resize, signals, frame pacing.
public final class TerminalOrbSession {
    public let engine = OrbEngine(width: 40, height: 20)
    public let renderer: TerminalOrbRenderer
    public let isTTY: Bool
    public private(set) var cols = 80, rows = 24
    public var interrupted = false
    public var accent: OrbColor = .amber
    private var origTermios = termios()
    private var rawOn = false
    private var active = false
    private var sources: [DispatchSourceSignal] = []
    private var resized = true
    private let start = Date()
    private var nextFrame = Date()
    public static let fps = 24.0

    public init() {
        isTTY = isatty(STDOUT_FILENO) != 0
        renderer = TerminalOrbRenderer(useColor: isatty(STDOUT_FILENO) != 0 && ProcessInfo.processInfo.environment["NO_COLOR"] == nil)
        updateSize()
    }

    public var elapsed: Double { Date().timeIntervalSince(start) }

    private func updateSize() {
        var w = winsize()
        if ioctl(STDOUT_FILENO, TIOCGWINSZ, &w) == 0, w.ws_col > 0, w.ws_row > 0 { cols = Int(w.ws_col); rows = Int(w.ws_row) }
    }

    private func write(_ s: String) { fputs(s, stdout); fflush(stdout) }

    public func enter() {
        guard isTTY, !active else { return }
        active = true
        write("\u{1B}[?1049h\u{1B}[?25l\u{1B}[2J")
        if isatty(STDIN_FILENO) != 0, tcgetattr(STDIN_FILENO, &origTermios) == 0 {
            var raw = origTermios
            raw.c_lflag &= ~tcflag_t(ICANON | ECHO)
            raw.c_cc.16 = 0; raw.c_cc.17 = 0   // VMIN, VTIME
            tcsetattr(STDIN_FILENO, TCSANOW, &raw); rawOn = true
        }
        for sig in [SIGINT, SIGTERM, SIGWINCH] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler { [weak self] in
                if sig == SIGWINCH { self?.updateSize(); self?.resized = true } else { self?.interrupted = true }
            }
            src.resume(); sources.append(src)
        }
    }

    public func leave() {
        guard active else { return }
        active = false
        sources.forEach { $0.cancel() }; sources = []
        for sig in [SIGINT, SIGTERM, SIGWINCH] { signal(sig, SIG_DFL) }
        if rawOn { tcsetattr(STDIN_FILENO, TCSANOW, &origTermios); rawOn = false }
        write("\u{1B}[0m\u{1B}[?25h\u{1B}[?1049l")
    }

    /// Non-blocking single key read (nil if none). Arrow keys are returned as "up","down","left","right".
    public func readKey() -> String? {
        guard rawOn else { return nil }
        var buf = [UInt8](repeating: 0, count: 8)
        let n = read(STDIN_FILENO, &buf, 8)
        guard n > 0 else { return nil }
        if n >= 3, buf[0] == 27, buf[1] == 91 {
            switch buf[2] { case 65: return "up"; case 66: return "down"; case 67: return "right"; case 68: return "left"; default: return nil }
        }
        if buf[0] == 3 { interrupted = true; return nil }
        return String(bytes: buf[0..<n], encoding: .utf8)
    }

    /// Render one frame (orb above `footer` lines). Returns the frame string when not a TTY (for pipes).
    public func draw(state: OrbState, amplitude: Double, footer: [String] = []) {
        updateSize()
        let footerRows = min(footer.count, max(0, rows - 6))
        let lines = Array(footer.suffix(footerRows))
        let orbRows = max(2, rows - footerRows)
        engine.resize(width: cols, height: orbRows * 2)
        engine.render(state: state, time: elapsed, amplitude: amplitude, accent: accent)
        if isTTY {
            write(renderer.renderDiff(grid: engine.pixels, cols: cols, rows: orbRows, footer: lines))
        }
    }

    /// Sleep until next frame boundary (~24 fps), low CPU.
    public func waitFrame() async {
        nextFrame = nextFrame.addingTimeInterval(1 / Self.fps)
        let d = nextFrame.timeIntervalSinceNow
        if d > 0 { try? await Task.sleep(nanoseconds: UInt64(d * 1e9)) } else { nextFrame = Date() }
    }
}
