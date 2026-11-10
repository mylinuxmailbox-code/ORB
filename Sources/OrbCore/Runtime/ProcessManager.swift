import Foundation
import Darwin

/// Description of a long-running child service.
public struct ServiceSpec: Sendable {
    public var name: String
    public var executable: String
    public var arguments: [String]
    public var environment: [String: String]
    public var workingDirectory: URL?
    public var restartOnCrash: Bool
    public init(name: String, executable: String, arguments: [String] = [], environment: [String: String] = [:],
                workingDirectory: URL? = nil, restartOnCrash: Bool = true) {
        self.name = name; self.executable = executable; self.arguments = arguments
        self.environment = environment; self.workingDirectory = workingDirectory; self.restartOnCrash = restartOnCrash
    }
}

/// Fan-out of log lines to any number of AsyncStream subscribers.
final class LogHub: @unchecked Sendable {
    private let lock = NSLock()
    private var subs: [UUID: AsyncStream<String>.Continuation] = [:]
    func subscribe() -> AsyncStream<String> {
        AsyncStream { cont in
            let id = UUID()
            lock.lock(); subs[id] = cont; lock.unlock()
            cont.onTermination = { [weak self] _ in
                guard let self else { return }
                self.lock.lock(); self.subs[id] = nil; self.lock.unlock()
            }
        }
    }
    func publish(_ s: String) {
        lock.lock(); let all = Array(subs.values); lock.unlock()
        for c in all { c.yield(s) }
    }
}

/// Per-service log file + hub + tail buffer.
final class LogSink: @unchecked Sendable {
    let name: String
    private let hub: LogHub
    private let lock = NSLock()
    private var file: FileHandle?
    private var tail: [String] = []
    init(name: String, hub: LogHub) {
        self.name = name; self.hub = hub
        let url = Paths.logs.appendingPathComponent("\(name).log")
        try? FileManager.default.createDirectory(at: Paths.logs, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        file = try? FileHandle(forWritingTo: url)
        _ = try? file?.seekToEnd()
    }
    func write(_ line: String) {
        lock.lock()
        tail.append(line); if tail.count > 30 { tail.removeFirst() }
        try? file?.write(contentsOf: Data((line + "\n").utf8))
        lock.unlock()
        hub.publish("[\(name)] \(line)")
    }
    func recent(_ n: Int = 8) -> String { lock.lock(); defer { lock.unlock() }; return tail.suffix(n).joined(separator: "\n") }
}

/// Tracks live child process groups for atexit/signal cleanup.
final class PidRegistry: @unchecked Sendable {
    static let shared = PidRegistry()
    private let lock = NSLock()
    private var pids = Set<pid_t>()
    private var installed = false
    private var sources: [DispatchSourceSignal] = []

    func add(_ p: pid_t) { lock.lock(); pids.insert(p); lock.unlock(); installHandlers() }
    func remove(_ p: pid_t) { lock.lock(); pids.remove(p); lock.unlock() }
    func contains(_ p: pid_t) -> Bool { lock.lock(); defer { lock.unlock() }; return pids.contains(p) }
    var all: [pid_t] { lock.lock(); defer { lock.unlock() }; return Array(pids) }

    func killAll() {
        let mine = all
        for p in mine { kill(-p, SIGTERM) }
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline, !all.isEmpty { usleep(50_000) }
        for p in all { kill(-p, SIGKILL) }
    }

    private func installHandlers() {
        lock.lock(); if installed { lock.unlock(); return }; installed = true; lock.unlock()
        atexit { PidRegistry.shared.killAll() }
        for sig in [SIGINT, SIGTERM, SIGHUP] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .global())
            src.setEventHandler {
                PidRegistry.shared.killAll()
                signal(sig, SIG_DFL); raise(sig)
            }
            src.resume()
            sources.append(src)
        }
    }
}

/// Launches and supervises child processes (each in its own process group).
public actor ProcessManager {
    public static let shared = ProcessManager()

    private struct Entry {
        var spec: ServiceSpec
        var pid: pid_t          // 0 while waiting to restart
        var generation: Int
        var failures: Int
        var startedAt: Date
        var stopping: Bool
    }
    private var entries: [String: Entry] = [:]
    private var sinks: [String: LogSink] = [:]
    private var generationCounter = 0
    private let hub = LogHub()

    public init() {}

    /// Stream of log lines from all services, prefixed `[name] `.
    public func logStream() -> AsyncStream<String> { hub.subscribe() }

    public func isRunning(_ name: String) -> Bool {
        guard let e = entries[name], !e.stopping else { return false }
        return e.pid != 0
    }
    public func pid(of name: String) -> pid_t? { entries[name].flatMap { $0.pid != 0 ? $0.pid : nil } }
    public func restartCount(_ name: String) -> Int { entries[name]?.failures ?? 0 }
    public func recentLog(_ name: String) -> String { sinks[name]?.recent() ?? "" }

    /// Start a service (no-op if already running).
    public func start(_ spec: ServiceSpec) throws {
        if let e = entries[spec.name], !e.stopping { return }
        try Paths.ensureAll()
        try launch(spec, failures: 0)
    }

    private func sink(_ name: String) -> LogSink {
        if let s = sinks[name] { return s }
        let s = LogSink(name: name, hub: hub); sinks[name] = s; return s
    }

    private func launch(_ spec: ServiceSpec, failures: Int) throws {
        var env = ProcessInfo.processInfo.environment
        let extra = "/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        env["PATH"] = (env["PATH"].map { $0 + ":" } ?? "") + extra
        for (k, v) in spec.environment { env[k] = v }
        let (pid, rfd) = try Spawner.spawn(path: spec.executable, args: spec.arguments, env: env, cwd: spec.workingDirectory)
        generationCounter += 1
        let gen = generationCounter
        entries[spec.name] = Entry(spec: spec, pid: pid, generation: gen, failures: failures, startedAt: Date(), stopping: false)
        PidRegistry.shared.add(pid)
        let sk = sink(spec.name)
        sk.write("--- started pid \(pid): \(spec.executable) \(spec.arguments.joined(separator: " "))")
        Spawner.readLines(fd: rfd) { sk.write($0) }
        let name = spec.name
        Thread.detachNewThread { [weak self] in
            var st: Int32 = 0
            while waitpid(pid, &st, 0) < 0 && errno == EINTR {}
            kill(-pid, SIGTERM)     // reap orphaned group members
            PidRegistry.shared.remove(pid)
            let code: Int32 = (st & 0x7f) == 0 ? (st >> 8) & 0xff : -(st & 0x7f)
            Task { await self?.exited(name: name, generation: gen, code: code) }
        }
    }

    private func exited(name: String, generation: Int, code: Int32) async {
        guard var e = entries[name], e.generation == generation else { return }
        if e.stopping { entries[name] = nil; return }
        let sk = sink(name)
        sk.write("--- exited with status \(code)")
        guard e.spec.restartOnCrash else { entries[name] = nil; return }
        let ranFor = Date().timeIntervalSince(e.startedAt)
        e.failures = (ranFor > 60 ? 0 : e.failures) + 1
        e.pid = 0
        entries[name] = e
        let delay = min(pow(2.0, Double(e.failures - 1)), 30)
        sk.write("--- restarting in \(Int(delay))s (failure #\(e.failures))")
        try? await Task.sleep(nanoseconds: UInt64(delay * 1e9))
        guard let cur = entries[name], cur.generation == generation, !cur.stopping else { return }
        do { try launch(cur.spec, failures: cur.failures) }
        catch { sk.write("--- restart failed: \(error.localizedDescription)"); entries[name] = nil }
    }

    /// Poll a URL until it answers HTTP < 500 (or process dies / timeout).
    public func waitHealthy(_ name: String, url: URL, timeout: TimeInterval = 60) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            try Task.checkCancellation()
            if await HTTP.isUp(url) { return }
            if entries[name] == nil {
                throw OrbError.message("\(name) exited during startup. Last log:\n\(recentLog(name))")
            }
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        throw OrbError.message("\(name) did not become healthy at \(url.absoluteString) within \(Int(timeout))s. Last log:\n\(recentLog(name)) (see \(Paths.logs.path)/\(name).log)")
    }

    public func stop(_ name: String) async {
        guard var e = entries[name] else { return }
        e.stopping = true; entries[name] = e
        if e.pid != 0 { await terminate(pids: [e.pid]) }
        entries[name] = nil
    }

    /// Terminate every managed process group.
    public func stopAll() async {
        var pids: [pid_t] = []
        for (n, var e) in entries { e.stopping = true; entries[n] = e; if e.pid != 0 { pids.append(e.pid) } }
        await terminate(pids: pids)
        entries.removeAll()
    }

    private func terminate(pids: [pid_t]) async {
        for p in pids { kill(-p, SIGTERM) }
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, pids.contains(where: { PidRegistry.shared.contains($0) }) {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        for p in pids where PidRegistry.shared.contains(p) { kill(-p, SIGKILL) }
        let d2 = Date().addingTimeInterval(2)
        while Date() < d2, pids.contains(where: { PidRegistry.shared.contains($0) }) {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }
}

enum Spawner {
    static func spawn(path: String, args: [String], env: [String: String], cwd: URL?) throws -> (pid_t, Int32) {
        guard FileManager.default.isExecutableFile(atPath: path) else {
            throw OrbError.message("Executable not found or not executable: \(path)")
        }
        var fds: [Int32] = [0, 0]
        guard pipe(&fds) == 0 else { throw OrbError.message("pipe() failed") }
        _ = fcntl(fds[0], F_SETFD, FD_CLOEXEC); _ = fcntl(fds[1], F_SETFD, FD_CLOEXEC)
        var fa: posix_spawn_file_actions_t? = nil
        posix_spawn_file_actions_init(&fa)
        defer { posix_spawn_file_actions_destroy(&fa) }
        posix_spawn_file_actions_adddup2(&fa, fds[1], 1)
        posix_spawn_file_actions_adddup2(&fa, fds[1], 2)
        posix_spawn_file_actions_addopen(&fa, 0, "/dev/null", O_RDONLY, 0)
        if let cwd { posix_spawn_file_actions_addchdir_np(&fa, cwd.path) }
        var attr: posix_spawnattr_t? = nil
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETPGROUP))
        posix_spawnattr_setpgroup(&attr, 0)
        let argv: [UnsafeMutablePointer<CChar>?] = ([path] + args).map { strdup($0) } + [nil]
        let envp: [UnsafeMutablePointer<CChar>?] = env.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { argv.forEach { free($0) }; envp.forEach { free($0) } }
        var pid: pid_t = 0
        let rc = posix_spawn(&pid, path, &fa, &attr, argv, envp)
        close(fds[1])
        guard rc == 0 else {
            close(fds[0])
            throw OrbError.message("Failed to launch \(path): \(String(cString: strerror(rc)))")
        }
        return (pid, fds[0])
    }

    static func readLines(fd: Int32, _ onLine: @escaping @Sendable (String) -> Void) {
        Thread.detachNewThread {
            var buf = Data()
            var chunk = [UInt8](repeating: 0, count: 8192)
            while true {
                let n = read(fd, &chunk, chunk.count)
                if n < 0 && errno == EINTR { continue }
                if n <= 0 { break }
                buf.append(chunk, count: n)
                while let i = buf.firstIndex(where: { $0 == 10 || $0 == 13 }) {
                    let line = String(decoding: buf[buf.startIndex..<i], as: UTF8.self)
                    buf.removeSubrange(buf.startIndex...i)
                    if !line.isEmpty { onLine(line) }
                }
            }
            if !buf.isEmpty { onLine(String(decoding: buf, as: UTF8.self)) }
            close(fd)
        }
    }
}

/// Minimal loopback HTTP helpers (no proxies).
enum HTTP {
    static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.connectionProxyDictionary = [:]
        c.waitsForConnectivity = false
        return URLSession(configuration: c)
    }()
    static func isUp(_ url: URL, timeout: TimeInterval = 2) async -> Bool {
        var r = URLRequest(url: url); r.timeoutInterval = timeout
        guard let (_, resp) = try? await session.data(for: r), let h = resp as? HTTPURLResponse else { return false }
        return h.statusCode < 500
    }
    static func send(_ url: URL, method: String = "GET", body: Data? = nil, headers: [String: String] = [:],
                     timeout: TimeInterval = 60) async throws -> (Data, Int) {
        var r = URLRequest(url: url); r.httpMethod = method; r.httpBody = body; r.timeoutInterval = timeout
        for (k, v) in headers { r.setValue(v, forHTTPHeaderField: k) }
        let (d, resp) = try await session.data(for: r)
        return (d, (resp as? HTTPURLResponse)?.statusCode ?? 0)
    }
}
