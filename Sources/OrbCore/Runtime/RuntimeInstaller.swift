import Foundation

public struct CommandResult: Sendable { public var status: Int32; public var output: String }

final class LineBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var partial = Data()
    private var all = Data()
    private let onLine: (@Sendable (String) -> Void)?
    init(_ onLine: (@Sendable (String) -> Void)?) { self.onLine = onLine }
    func feed(_ d: Data) {
        lock.lock(); all.append(d); partial.append(d)
        var lines: [String] = []
        while let i = partial.firstIndex(where: { $0 == 10 || $0 == 13 }) {
            let l = String(decoding: partial[partial.startIndex..<i], as: UTF8.self)
            partial.removeSubrange(partial.startIndex...i)
            if !l.isEmpty { lines.append(l) }
        }
        lock.unlock()
        lines.forEach { onLine?($0) }
    }
    func flush() { lock.lock(); let p = partial; partial = Data(); lock.unlock(); if !p.isEmpty { onLine?(String(decoding: p, as: UTF8.self)) } }
    var text: String { lock.lock(); defer { lock.unlock() }; return String(decoding: all, as: UTF8.self) }
}

public enum Shell {
    /// Run a command to completion, streaming merged stdout/stderr lines to `log`. Cancellation terminates it.
    public static func run(_ exe: String, _ args: [String], env: [String: String] = [:], cwd: URL? = nil,
                           log: (@Sendable (String) -> Void)? = nil) async throws -> CommandResult {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        var e = ProcessInfo.processInfo.environment
        e["PATH"] = (e["PATH"].map { $0 + ":" } ?? "") + "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        for (k, v) in env { e[k] = v }
        p.environment = e
        if let cwd { p.currentDirectoryURL = cwd }
        p.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        p.standardOutput = pipe; p.standardError = pipe
        let buf = LineBuffer(log)
        pipe.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil } else { buf.feed(d) }
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<CommandResult, Error>) in
                p.terminationHandler = { proc in
                    pipe.fileHandleForReading.readabilityHandler = nil
                    if let rest = try? pipe.fileHandleForReading.readToEnd() { buf.feed(rest) }
                    buf.flush()
                    cont.resume(returning: CommandResult(status: proc.terminationStatus, output: buf.text))
                }
                do { try p.run() } catch {
                    pipe.fileHandleForReading.readabilityHandler = nil
                    cont.resume(throwing: OrbError.message("Cannot run \(exe): \(error.localizedDescription)"))
                }
            }
        } onCancel: { if p.isRunning { p.terminate() } }
    }

    /// Quick synchronous run (for version probes).
    public static func runSync(_ exe: String, _ args: [String]) -> CommandResult? {
        let p = Process(); p.executableURL = URL(fileURLWithPath: exe); p.arguments = args
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe; p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let d = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
        p.waitUntilExit()
        return CommandResult(status: p.terminationStatus, output: String(decoding: d, as: UTF8.self))
    }
}

/// Locates or installs the third-party runtimes ORB depends on. All operations are idempotent.
public struct RuntimeInstaller: Sendable {
    public typealias Log = @Sendable (String) -> Void
    let log: Log
    public init(log: @escaping Log = { _ in }) { self.log = log }

    static let searchDirs = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]

    // MARK: Locating
    public static func which(_ name: String) -> URL? {
        var dirs = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        dirs = [Paths.bin.path] + dirs + searchDirs
        for d in dirs {
            let p = d + "/" + name
            if FileManager.default.isExecutableFile(atPath: p) { return URL(fileURLWithPath: p) }
        }
        return nil
    }
    public static var brewPath: URL? { which("brew") }

    public func ollamaPath() -> URL? {
        let fixed = ["/opt/homebrew/bin/ollama", "/usr/local/bin/ollama",
                     "/Applications/Ollama.app/Contents/Resources/ollama",
                     Paths.bin.appendingPathComponent("ollama-dist/ollama").path,
                     Paths.bin.appendingPathComponent("ollama-dist/Ollama.app/Contents/Resources/ollama").path]
        for p in fixed where FileManager.default.isExecutableFile(atPath: p) { return URL(fileURLWithPath: p) }
        return Self.which("ollama")
    }
    public func whisperServerPath() -> URL? {
        for n in ["whisper-server", "whisper-cpp-server"] { if let u = Self.which(n) { return u } }
        return nil
    }
    public var venvPython: URL { Paths.venv.appendingPathComponent("bin/python") }

    static func pythonVersion(_ path: String) -> (Int, Int)? {
        guard FileManager.default.isExecutableFile(atPath: path),
              let r = Shell.runSync(path, ["-c", "import sys;print(sys.version_info[0],sys.version_info[1])"]), r.status == 0 else { return nil }
        let parts = r.output.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ").compactMap { Int($0) }
        return parts.count == 2 ? (parts[0], parts[1]) : nil
    }

    /// Best system Python: prefers 3.10–3.13 (wheel availability for onnxruntime), accepts newer as a last resort.
    public func systemPython() -> (url: URL, version: (Int, Int))? {
        var cands: [String] = []
        for v in ["3.12", "3.11", "3.13", "3.10"] {
            for pre in ["/opt/homebrew/opt/python@\(v)/bin", "/usr/local/opt/python@\(v)/bin", "/opt/homebrew/bin", "/usr/local/bin"] {
                cands.append("\(pre)/python\(v)")
            }
            if let u = Self.which("python\(v)") { cands.append(u.path) }
        }
        for v in ["3.14", "3.15"] { if let u = Self.which("python\(v)") { cands.append(u.path) } }
        if let u = Self.which("python3") { cands.append(u.path) }
        var fallback: (URL, (Int, Int))?
        for c in cands {
            guard let ver = Self.pythonVersion(c), ver.0 == 3, ver.1 >= 10 else { continue }
            if ver.1 <= 13 { return (URL(fileURLWithPath: c), ver) }
            if fallback == nil { fallback = (URL(fileURLWithPath: c), ver) }
        }
        return fallback.map { (url: $0.0, version: $0.1) }
    }

    // MARK: Installing
    func brew(_ args: [String]) async throws {
        guard let b = Self.brewPath else { throw OrbError.message("Homebrew is not installed. Install it from https://brew.sh and re-run setup.") }
        log("$ brew \(args.joined(separator: " "))")
        let r = try await Shell.run(b.path, args, env: ["HOMEBREW_NO_AUTO_UPDATE": "1", "NONINTERACTIVE": "1", "HOMEBREW_NO_ENV_HINTS": "1"], log: log)
        guard r.status == 0 else { throw OrbError.message("`brew \(args.joined(separator: " "))` failed (exit \(r.status)). \(Self.tail(r.output))") }
    }
    static func tail(_ s: String, _ n: Int = 6) -> String { s.split(separator: "\n").suffix(n).joined(separator: "\n") }

    public func ensureOllama() async throws -> URL {
        if let p = ollamaPath() { log("Ollama found: \(p.path)"); return p }
        try Paths.ensureAll()
        if Self.brewPath != nil {
            do { try await brew(["install", "ollama"]); if let p = ollamaPath() { return p } }
            catch { log("brew install ollama failed: \(error.localizedDescription) — falling back to release download") }
        }
        let dist = Paths.bin.appendingPathComponent("ollama-dist", isDirectory: true)
        let tmp = Paths.cache
        for (asset, isZip) in [("ollama-darwin.tgz", false), ("Ollama-darwin.zip", true)] {
            let url = URL(string: "https://github.com/ollama/ollama/releases/latest/download/\(asset)")!
            log("Downloading \(url.absoluteString)")
            do {
                let (file, resp) = try await URLSession.shared.download(from: url)
                guard (resp as? HTTPURLResponse)?.statusCode == 200 else { log("HTTP \((resp as? HTTPURLResponse)?.statusCode ?? 0) for \(asset)"); continue }
                let archive = tmp.appendingPathComponent(asset)
                try? FileManager.default.removeItem(at: archive)
                try FileManager.default.moveItem(at: file, to: archive)
                try? FileManager.default.removeItem(at: dist)
                try FileManager.default.createDirectory(at: dist, withIntermediateDirectories: true)
                let r = isZip ? try await Shell.run("/usr/bin/ditto", ["-x", "-k", archive.path, dist.path], log: log)
                              : try await Shell.run("/usr/bin/tar", ["-xzf", archive.path, "-C", dist.path], log: log)
                guard r.status == 0 else { continue }
                _ = Shell.runSync("/usr/bin/xattr", ["-dr", "com.apple.quarantine", dist.path])
                if let p = ollamaPath() { log("Ollama installed at \(p.path)"); return p }
            } catch is CancellationError { throw CancellationError() }
            catch { log("Download of \(asset) failed: \(error.localizedDescription)") }
        }
        throw OrbError.message("Could not install Ollama automatically. Install it from https://ollama.com/download (or `brew install ollama`) and re-run setup.")
    }

    public func ensureWhisper() async throws -> URL {
        if let p = whisperServerPath() { log("whisper-server found: \(p.path)"); return p }
        guard Self.brewPath != nil else {
            throw OrbError.message("whisper-server not found and Homebrew is unavailable. Install Homebrew (https://brew.sh) then run `brew install whisper-cpp`, or build whisper.cpp and put `whisper-server` on your PATH.")
        }
        try await brew(["install", "whisper.cpp"])
        if let p = whisperServerPath() { return p }
        throw OrbError.message("`brew install whisper-cpp` completed but `whisper-server` was not found. Your brew version of whisper-cpp may lack the server binary; build whisper.cpp from source (cmake -B build && cmake --build build -t whisper-server) and put it on PATH.")
    }

    public func ensurePython() async throws -> URL {
        if let (u, v) = systemPython(), v.1 <= 13 { log("Python \(v.0).\(v.1) found: \(u.path)"); return u }
        if Self.brewPath != nil {
            try await brew(["install", "python@3.12"])
            if let (u, v) = systemPython() { log("Python \(v.0).\(v.1): \(u.path)"); return u }
        }
        if let (u, v) = systemPython() { log("Using Python \(v.0).\(v.1) at \(u.path) (newer than tested)"); return u }
        throw OrbError.message("Python 3.10+ not found and Homebrew is unavailable. Install Python from https://python.org (or Homebrew + `brew install python@3.12`).")
    }

    func venvWorks() -> Bool {
        guard FileManager.default.isExecutableFile(atPath: venvPython.path) else { return false }
        return Shell.runSync(venvPython.path, ["-c", "import sys; print(sys.version)"])?.status == 0
    }

    public func ensureVenv(python: URL? = nil) async throws -> URL {
        if venvWorks() { log("Virtualenv OK: \(Paths.venv.path)"); return venvPython }
        let py: URL
        if let python { py = python } else { py = try await ensurePython() }
        try Paths.ensureAll()
        try? FileManager.default.removeItem(at: Paths.venv)
        log("$ \(py.path) -m venv \(Paths.venv.path)")
        let r = try await Shell.run(py.path, ["-m", "venv", Paths.venv.path], log: log)
        guard r.status == 0, venvWorks() else { throw OrbError.message("Creating the Python virtualenv failed. \(Self.tail(r.output))") }
        return venvPython
    }

    public func piperImportable() -> Bool {
        Shell.runSync(venvPython.path, ["-c", "import piper, aiohttp"])?.status == 0
    }

    /// Install piper-tts + aiohttp into the venv (retrying with Python 3.12 if the current interpreter is too new).
    public func ensurePiper() async throws {
        if piperImportable() { log("piper-tts and aiohttp already installed"); return }
        var attempt = 0
        while true {
            attempt += 1
            log("$ pip install piper-tts aiohttp")
            let r = try await Shell.run(venvPython.path, ["-m", "pip", "install", "--disable-pip-version-check", "piper-tts", "aiohttp"], log: log)
            if r.status == 0, piperImportable() { return }
            let ver = Self.pythonVersion(venvPython.path)
            if attempt == 1, let ver, ver.1 > 13, Self.brewPath != nil {
                log("pip install failed on Python \(ver.0).\(ver.1); retrying with Python 3.12")
                try await brew(["install", "python@3.12"])
                try? FileManager.default.removeItem(at: Paths.venv)
                guard let (u, v) = systemPython(), v.1 <= 13 else { throw OrbError.message("Python 3.12 install did not provide a usable interpreter.") }
                _ = try await ensureVenv(python: u)
                continue
            }
            throw OrbError.message("Installing piper-tts failed (Python \(ver.map { "\($0.0).\($0.1)" } ?? "?")). \(Self.tail(r.output))")
        }
    }

    /// Everything needed to run (no models).
    public func ensureAll() async throws {
        _ = try await ensureOllama()
        _ = try await ensureWhisper()
        _ = try await ensureVenv()
        try await ensurePiper()
    }
}
