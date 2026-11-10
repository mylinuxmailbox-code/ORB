import Foundation
import OrbCore

enum Ansi {
    static var color: Bool { isatty(STDOUT_FILENO) != 0 && ProcessInfo.processInfo.environment["NO_COLOR"] == nil }
    static func c(_ code: String, _ s: String) -> String { color ? "\u{1B}[\(code)m\(s)\u{1B}[0m" : s }
    static func bold(_ s: String) -> String { c("1", s) }
    static func dim(_ s: String) -> String { c("2", s) }
    static func green(_ s: String) -> String { c("32", s) }
    static func red(_ s: String) -> String { c("31", s) }
    static func yellow(_ s: String) -> String { c("33", s) }
    static func amber(_ s: String) -> String { c("38;2;255;158;31", s) }
}

func fail(_ msg: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data((Ansi.red("error: ") + msg + "\n").utf8))
    exit(code)
}

func fmtBytes(_ b: Int64) -> String {
    let u = ["B", "KB", "MB", "GB", "TB"]; var v = Double(b), i = 0
    while v >= 1024, i < u.count - 1 { v /= 1024; i += 1 }
    return i == 0 ? "\(b) B" : String(format: "%.1f %@", v, u[i])
}
func fmtETA(_ s: Double?) -> String {
    guard let s, s.isFinite, s >= 0 else { return "--:--" }
    let t = Int(s); return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, t % 3600 / 60, t % 60) : String(format: "%02d:%02d", t / 60, t % 60)
}
func bar(_ p: Double, width: Int = 30) -> String {
    let f = Int((max(0, min(1, p)) * Double(width)).rounded())
    return "[" + String(repeating: "█", count: f) + String(repeating: "░", count: width - f) + String(format: "] %3d%%", Int(p * 100))
}
func pad(_ s: String, _ n: Int) -> String { s.count >= n ? String(s.prefix(n)) : s + String(repeating: " ", count: n - s.count) }

/// Quick HTTP GET health probe.
func probe(_ url: URL, timeout: TimeInterval = 1.5) async -> (ok: Bool, detail: String) {
    var req = URLRequest(url: url); req.timeoutInterval = timeout
    do {
        let (_, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        return (code < 500 && code > 0, "HTTP \(code)")
    } catch { return (false, "unreachable") }
}

/// TCP connect test (is something listening on the loopback port?).
func portOpen(_ port: UInt16) -> Bool {
    let fd = socket(AF_INET, SOCK_STREAM, 0); if fd < 0 { return false }
    defer { close(fd) }
    var a = sockaddr_in(); a.sin_family = sa_family_t(AF_INET); a.sin_port = port.bigEndian
    a.sin_addr.s_addr = inet_addr("127.0.0.1")
    return withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0 } }
}

func which(_ tool: String) -> String? {
    var dirs = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
    dirs += ["/opt/homebrew/bin", "/usr/local/bin", "/Applications/Ollama.app/Contents/Resources"]
    return dirs.map { "\($0)/\(tool)" }.first { FileManager.default.isExecutableFile(atPath: $0) }
}

func shell(_ cmd: String) -> String {
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/sh"); p.arguments = ["-c", cmd]
    let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
    do { try p.run() } catch { return "" }
    let d = out.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
    return String(decoding: d, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
}

func parseFlags(_ args: [String]) -> (flags: [String: String], positional: [String]) {
    var f: [String: String] = [:], pos: [String] = [], i = 0
    while i < args.count {
        let a = args[i]
        if a.hasPrefix("--") {
            if let eq = a.firstIndex(of: "=") { f[String(a[a.index(a.startIndex, offsetBy: 2)..<eq])] = String(a[a.index(after: eq)...]) }
            else if i + 1 < args.count, !args[i + 1].hasPrefix("--") { f[String(a.dropFirst(2))] = args[i + 1]; i += 1 }
            else { f[String(a.dropFirst(2))] = "true" }
        } else { pos.append(a) }
        i += 1
    }
    return (f, pos)
}
