import Foundation

/// One rendered grid cell. `r,g,b` are the colour (0...1); `a` is intensity/alpha (0...1).
public struct OrbPixel: Sendable, Equatable {
    public var r: Float, g: Float, b: Float, a: Float
    public init(r: Float = 0, g: Float = 0, b: Float = 0, a: Float = 0) { self.r = r; self.g = g; self.b = b; self.a = a }
    public static let clear = OrbPixel()
}

public struct OrbColor: Sendable, Equatable {
    public var r: Float, g: Float, b: Float
    public init(r: Float, g: Float, b: Float) { self.r = r; self.g = g; self.b = b }
    public static let amber = OrbColor(r: 1.0, g: 0.62, b: 0.12)
}

/// Pure, UI-independent software renderer of a lit, rotating, noisy 3D sphere.
/// Deterministic: output depends only on (state history, time, amplitude, accent).
public final class OrbEngine {
    public private(set) var width: Int
    public private(set) var height: Int
    public private(set) var pixels: [OrbPixel]

    struct Params {
        var rot: Float = 0.25        // rotation speed rad/s
        var pulse: Float = 0         // pulse depth
        var pulseRate: Float = 2     // Hz
        var core: Float = 0.35       // core glow
        var swirl: Float = 0.3       // noise evolution speed
        var bright: Float = 0.8
        var flicker: Float = 0
        var red: Float = 0           // mix towards red
        var particles: Float = 0
        var amp: Float = 0           // amplitude reaction
        var breath: Float = 0.03
        var flash: Float = 0
        var contrast: Float = 0.5    // noise contrast
        var size: Float = 0.78
        mutating func lerp(to t: Params, _ k: Float) {
            func l(_ a: inout Float, _ b: Float) { a += (b - a) * k }
            l(&rot, t.rot); l(&pulse, t.pulse); l(&pulseRate, t.pulseRate); l(&core, t.core); l(&swirl, t.swirl)
            l(&bright, t.bright); l(&flicker, t.flicker); l(&red, t.red); l(&particles, t.particles)
            l(&amp, t.amp); l(&breath, t.breath); l(&flash, t.flash); l(&contrast, t.contrast); l(&size, t.size)
        }
    }

    struct Particle { var x: Float = 0, y: Float = 0, vx: Float = 0, vy: Float = 0, life: Float = 0 }

    private var params = Params()
    private var particles = [Particle](repeating: Particle(), count: 64)
    private var rng: UInt64 = 0x9E3779B97F4A7C15
    private var lastTime: Double? = nil
    private var angle: Float = 0
    private var phase: Float = 0
    private var ampSmooth: Float = 0
    private var emitAcc: Float = 0
    private var stateTime: Float = 0
    private var currentState: OrbState = .idle

    public init(width: Int, height: Int) {
        self.width = max(1, width); self.height = max(1, height)
        pixels = [OrbPixel](repeating: .clear, count: self.width * self.height)
    }

    public func resize(width: Int, height: Int) {
        let w = max(1, width), h = max(1, height)
        guard w != self.width || h != self.height else { return }
        self.width = w; self.height = h
        pixels = [OrbPixel](repeating: .clear, count: w * h)
    }

    static func target(for s: OrbState) -> Params {
        var p = Params()
        switch s {
        case .idle:         p.rot = 0.25; p.breath = 0.035; p.core = 0.30; p.bright = 0.75
        case .downloading:  p.rot = 0.35; p.pulse = 0.05; p.pulseRate = 1.6; p.particles = 1; p.core = 0.5; p.swirl = 0.4; p.bright = 0.9
        case .installing:   p.rot = 0.9; p.swirl = 1.4; p.core = 0.45; p.contrast = 0.8; p.bright = 0.9
        case .initializing: p.rot = 0.6; p.pulse = 0.12; p.pulseRate = 0.7; p.flash = 1; p.core = 0.7; p.swirl = 0.8; p.bright = 1.0
        case .ready:        p.rot = 0.18; p.breath = 0.02; p.core = 0.6; p.bright = 1.0; p.contrast = 0.3
        case .listening:    p.rot = 0.3; p.amp = 1; p.core = 0.5; p.bright = 0.95; p.breath = 0.015
        case .thinking:     p.rot = 0.5; p.swirl = 1.8; p.core = 1.0; p.bright = 1.0; p.contrast = 0.7; p.pulse = 0.02; p.pulseRate = 3
        case .speaking:     p.rot = 0.35; p.amp = 1; p.core = 0.75; p.bright = 1.0; p.pulse = 0.03; p.pulseRate = 4
        case .error:        p.rot = 0.08; p.red = 1; p.flicker = 1; p.core = 0.25; p.bright = 0.65; p.swirl = 0.1
        }
        return p
    }

    // ---- noise ----
    @inline(__always) private static func hash(_ x: Int32, _ y: Int32, _ z: Int32) -> Float {
        var h = UInt32(bitPattern: x) &* 374761393 &+ UInt32(bitPattern: y) &* 668265263 &+ UInt32(bitPattern: z) &* 2147483647
        h = (h ^ (h >> 13)) &* 1274126177
        h ^= h >> 16
        return Float(h & 0xFFFF) / 65535
    }
    @inline(__always) private static func vnoise(_ x: Float, _ y: Float, _ z: Float) -> Float {
        let xf = x.rounded(.down), yf = y.rounded(.down), zf = z.rounded(.down)
        let xi = Int32(xf), yi = Int32(yf), zi = Int32(zf)
        var fx = x - xf, fy = y - yf, fz = z - zf
        fx = fx * fx * (3 - 2 * fx); fy = fy * fy * (3 - 2 * fy); fz = fz * fz * (3 - 2 * fz)
        @inline(__always) func m(_ a: Float, _ b: Float, _ t: Float) -> Float { a + (b - a) * t }
        let a = m(hash(xi, yi, zi), hash(xi+1, yi, zi), fx), b = m(hash(xi, yi+1, zi), hash(xi+1, yi+1, zi), fx)
        let c = m(hash(xi, yi, zi+1), hash(xi+1, yi, zi+1), fx), d = m(hash(xi, yi+1, zi+1), hash(xi+1, yi+1, zi+1), fx)
        return m(m(a, b, fy), m(c, d, fy), fz)
    }

    @inline(__always) private func rand() -> Float {
        rng ^= rng << 13; rng ^= rng >> 7; rng ^= rng << 17
        return Float(rng >> 40) / Float(1 << 24)
    }

    /// Renders one frame into `pixels`.
    public func render(state: OrbState, time: Double, amplitude: Double = 0, accent: OrbColor = .amber) {
        let firstFrame = (lastTime == nil)
        let dt = Float(min(0.1, max(0, time - (lastTime ?? time))))
        lastTime = time
        if state != currentState { currentState = state; stateTime = 0 }
        stateTime += dt
        if firstFrame {
            params = Self.target(for: state)
            angle = Float(time) * params.rot
            phase = Float(time) * params.swirl
        } else {
            params.lerp(to: Self.target(for: state), min(1, dt * 4))
        }
        let p = params
        let amp = Float(max(0, min(1, amplitude)))
        ampSmooth += (amp - ampSmooth) * min(1, dt * 12)
        let a = ampSmooth * p.amp
        angle += p.rot * dt * (1 + a * 1.5)
        phase += p.swirl * dt
        let t = Float(time)

        var flick: Float = 1
        if p.flicker > 0.01 {
            let n = Self.vnoise(t * 9, 3.1, 0.7)
            flick = 1 - p.flicker * (n > 0.65 ? 0.6 : n * 0.3)
        }
        let breath = sinf(t * 1.3) * p.breath + sinf(t * p.pulseRate * 2 * .pi) * p.pulse + a * 0.12
        var flashK: Float = 0
        if p.flash > 0.01 { let c = fmodf(t, 2.4) / 2.4; flashK = p.flash * powf(max(0, 1 - c * 3), 2) }

        let W = width, H = height
        let scale = Float(min(W, H)) * 0.5
        let R = p.size * (1 + breath)
        let cx = Float(W) * 0.5, cy = Float(H) * 0.5
        let ca = cosf(angle), sa = sinf(angle)
        let tilt: Float = 0.35, ct = cosf(tilt), st = sinf(tilt)
        // accent, mixed to red for error
        let cr = accent.r + (0.9 - accent.r) * p.red, cg = accent.g + (0.1 - accent.g) * p.red, cb = accent.b + (0.05 - accent.b) * p.red
        let lx: Float = -0.45, ly: Float = -0.55, lz: Float = 0.70
        let ll = 1 / sqrtf(lx*lx + ly*ly + lz*lz)
        let LX = lx * ll, LY = ly * ll, LZ = lz * ll
        let coreK = p.core * (1 + flashK * 1.5 + a * 0.8)
        let wob = a * 0.5 + p.swirl * 0.15

        pixels.withUnsafeMutableBufferPointer { buf in
            for y in 0..<H {
                let ny = (Float(y) + 0.5 - cy) / scale
                for x in 0..<W {
                    let nx = (Float(x) + 0.5 - cx) / scale
                    let r2 = nx*nx + ny*ny
                    let rr = r2 / (R*R)
                    var inten: Float = 0
                    var glow: Float = 0
                    if rr < 1 {
                        let z = sqrtf(1 - rr)
                        let px = nx / R, py = ny / R
                        // surface point rotated: Y rotation + tilt
                        let rx = px * ca + z * sa, rz = -px * sa + z * ca
                        let ry = py * ct - rz * st, rz2 = py * st + rz * ct
                        let k: Float = 2.4
                        let n1 = Self.vnoise(rx * k + phase, ry * k, rz2 * k - phase * 0.7)
                        let n2 = Self.vnoise(rx * k * 2.1 - phase * 0.5, ry * k * 2.1 + phase, rz2 * k * 2.1 + wob)
                        let n = n1 * 0.65 + n2 * 0.35
                        let lam = max(0, px * LX + py * LY + z * LZ)
                        let surf = 0.25 + (1 - p.contrast) * 0.35 + n * p.contrast * 0.9
                        let shade = 0.18 + lam * 0.85
                        let rim = powf(1 - z, 3) * 0.9
                        let core = coreK * powf(z, 6) * (0.6 + 0.4 * n)
                        inten = (surf * shade + rim + core + flashK * 0.4) * p.bright * flick
                        // soft edge
                        let edge = min(1, (1 - rr) * 14)
                        inten *= 0.4 + 0.6 * edge
                        glow = 0
                    } else {
                        let d = sqrtf(rr) - 1
                        glow = expf(-d * 5.5) * (0.28 + coreK * 0.18 + a * 0.35 + flashK * 0.5) * p.bright * flick
                    }
                    let v = max(0, inten + glow)
                    let al = min(1, v)
                    // hotter colours toward white as intensity exceeds 1
                    let hot = max(0, v - 0.85) * 0.8
                    buf[y * W + x] = OrbPixel(r: min(1, cr + hot), g: min(1, cg + hot), b: min(1, cb + hot), a: al)
                }
            }
        }

        // particles
        if p.particles > 0.02 {
            emitAcc += dt * 30 * p.particles
            while emitAcc >= 1 {
                emitAcc -= 1
                if let i = particles.firstIndex(where: { $0.life <= 0 }) {
                    let th = rand() * 2 * .pi, dist: Float = 1.15 + rand() * 0.2
                    let sp = 0.25 + rand() * 0.25
                    particles[i] = Particle(x: cosf(th) * dist, y: sinf(th) * dist, vx: -cosf(th) * sp, vy: -sinf(th) * sp, life: 1)
                }
            }
        }
        for i in particles.indices where particles[i].life > 0 {
            particles[i].x += particles[i].vx * dt; particles[i].y += particles[i].vy * dt
            particles[i].life -= dt * 0.55
            if particles[i].x * particles[i].x + particles[i].y * particles[i].y < R * R * 0.9 { particles[i].life = 0 }
            let ix = Int(cx + particles[i].x * scale), iy = Int(cy + particles[i].y * scale)
            if ix >= 0, ix < W, iy >= 0, iy < H, particles[i].life > 0 {
                let l = min(1, particles[i].life * 1.5)
                var px = pixels[iy * W + ix]
                px.a = min(1, px.a + l * 0.9)
                px.r = min(1, cr + 0.3); px.g = min(1, cg + 0.3); px.b = min(1, cb + 0.3)
                pixels[iy * W + ix] = px
            }
        }
    }
}
