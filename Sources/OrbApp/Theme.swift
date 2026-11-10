import SwiftUI
import OrbCore

enum T {
    static let bg = Color(red: 0.055, green: 0.055, blue: 0.06)
    static let panel = Color(red: 0.09, green: 0.09, blue: 0.10)
    static let line = Color.white.opacity(0.10)
    static let text = Color(red: 0.93, green: 0.92, blue: 0.89)
    static let dim = Color(red: 0.93, green: 0.92, blue: 0.89).opacity(0.55)
    static let amber = Color(red: 1.0, green: 0.69, blue: 0.0)
    static let red = Color(red: 1.0, green: 0.33, blue: 0.28)
    static let green = Color(red: 0.45, green: 0.85, blue: 0.5)
    static func mono(_ s: CGFloat, _ w: Font.Weight = .regular) -> Font { .system(size: s, weight: w, design: .monospaced) }
    static func sans(_ s: CGFloat, _ w: Font.Weight = .regular) -> Font { .system(size: s, weight: w) }
}

struct Tag: View {
    let text: String; var color: Color = T.dim
    var body: some View {
        Text(text).font(T.mono(10, .medium)).foregroundStyle(color)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .overlay(Rectangle().stroke(color.opacity(0.6), lineWidth: 1))
    }
}

struct CompatBadge: View {
    let c: Compatibility
    var body: some View {
        Tag(text: c == .verified ? "VERIFIED" : "EXPERIMENTAL", color: c == .verified ? T.green : T.amber)
    }
}

struct PixelButton: View {
    let title: String; var primary = false; var disabled = false; let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title).font(T.mono(primary ? 15 : 12, .bold)).tracking(1.5)
                .foregroundStyle(primary ? Color.black : T.text)
                .padding(.horizontal, primary ? 36 : 14).padding(.vertical, primary ? 16 : 8)
                .background(primary ? T.amber : Color.clear)
                .overlay(Rectangle().stroke(primary ? T.amber : T.line, lineWidth: 1))
                .shadow(color: primary ? T.amber.opacity(0.35) : .clear, radius: 14)
        }
        .buttonStyle(.plain).disabled(disabled).opacity(disabled ? 0.4 : 1)
    }
}

func fmtBytes(_ b: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: b, countStyle: .file)
}
func fmtETA(_ s: Double?) -> String {
    guard let s, s.isFinite else { return "--" }
    let i = Int(s); return i >= 60 ? "\(i/60)m \(i%60)s" : "\(i)s"
}

/// Pixel orb drawn from OrbEngine on a Canvas.
struct OrbView: View {
    var state: OrbState
    var amplitude: Double = 0
    var grid = 40
    var body: some View {
        TimelineView(.animation) { tl in
            Canvas { ctx, size in
                let engine = OrbEngine(width: grid, height: grid)
                engine.render(state: state, time: tl.date.timeIntervalSinceReferenceDate, amplitude: amplitude)
                let n = engine.width
                let cell = min(size.width, size.height) / CGFloat(n)
                let ox = (size.width - cell * CGFloat(n)) / 2, oy = (size.height - cell * CGFloat(engine.height)) / 2
                for y in 0..<engine.height { for x in 0..<n {
                    let p = engine.pixels[y * n + x]
                    if p.a <= 0.01 { continue }
                    let rect = CGRect(x: ox + CGFloat(x) * cell, y: oy + CGFloat(y) * cell, width: cell, height: cell)
                    ctx.fill(Path(rect), with: .color(Color(red: Double(p.r), green: Double(p.g), blue: Double(p.b), opacity: Double(p.a))))
                } }
            }
        }
        .shadow(color: T.amber.opacity(0.25), radius: 30)
    }
}
