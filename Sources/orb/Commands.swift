import Foundation
import AVFoundation
import OrbCore

let usage = """
orb — local voice assistant

USAGE: orb <command> [options]

  demo [state]               Animated orb (states: \(OrbState.allCases.map(\.rawValue).joined(separator: ", ")))
  doctor                     Diagnose hardware, runtimes, services, disk, mic, ports
  models <stt|tts|llm> [q]   Browse / search the model catalog
  setup [--llm TAG --stt ID --tts ID]
                             Install & verify the stack (recommended defaults if omitted)
  use [--llm TAG --stt ID --tts ID]
                             Hot-swap STT, TTS, or LLM (catalog id, HF repo, or local .bin/.onnx path)
  run                        Start the voice agent in the terminal
  chat                       Text chat with the configured LLM
  status                     Show config and service status
  stop                       Stop ORB background services
  help                       This message
"""

// MARK: demo
@MainActor func cmdDemo(_ args: [String]) async {
    var state = OrbState.idle
    var auto = true
    if let a = args.first {
        guard let s = OrbState(rawValue: a) else { fail("unknown state '\(a)'. Try: \(OrbState.allCases.map(\.rawValue).joined(separator: ", "))") }
        state = s; auto = false
    }
    let ses = TerminalOrbSession()
    if !ses.isTTY {
        // Non-TTY: print a single plain frame per state.
        let states = auto ? OrbState.allCases : [state]
        for s in states {
            for i in 0..<30 { ses.engine.resize(width: 60, height: 28); ses.engine.render(state: s, time: Double(i) / 24, amplitude: 0.5) }
            print("== \(s.rawValue) ==")
            print(TerminalOrbRenderer(useColor: false).renderString(grid: ses.engine.pixels, cols: 60, rows: 14))
        }
        return
    }
    ses.enter(); defer { ses.leave() }
    let all = OrbState.allCases
    var idx = all.firstIndex(of: state) ?? 0
    var lastSwitch = ses.elapsed
    var manualAmp: Double? = nil
    while !ses.interrupted {
        while let k = ses.readKey() {
            switch k {
            case "q", "Q": ses.interrupted = true
            case "right", "n", " ": idx = (idx + 1) % all.count; auto = false
            case "left", "p": idx = (idx + all.count - 1) % all.count; auto = false
            case "a": auto.toggle(); lastSwitch = ses.elapsed
            case "m": manualAmp = manualAmp == nil ? 0.8 : nil
            case "1"..."9": idx = min(all.count - 1, Int(k)! - 1); auto = false
            default: break
            }
        }
        if auto, ses.elapsed - lastSwitch > 4 { idx = (idx + 1) % all.count; lastSwitch = ses.elapsed }
        let t = ses.elapsed
        let amp = manualAmp ?? (0.5 + 0.5 * sin(t * 5.3) * sin(t * 1.7 + 1)).clamped(0, 1)
        let s = all[idx]
        let line1 = "  " + Ansi.amber("● " + s.rawValue) + Ansi.dim("   [←/→ or 1-9] state  [a] auto:\(auto ? "on" : "off")  [m] amp:\(manualAmp == nil ? "wave" : "hold")  [q] quit")
        ses.draw(state: s, amplitude: amp, footer: [line1])
        await ses.waitFrame()
    }
}

extension Double { func clamped(_ lo: Double, _ hi: Double) -> Double { Swift.min(hi, Swift.max(lo, self)) } }

// MARK: doctor
@MainActor func cmdDoctor() async {
    func row(_ ok: Bool?, _ k: String, _ v: String) {
        let mark = ok == nil ? Ansi.yellow("•") : ok! ? Ansi.green("✓") : Ansi.red("✗")
        print("  \(mark) \(pad(k, 18)) \(v)")
    }
    print(Ansi.bold("Hardware"))
    let hw = await HardwareDetector().detect()
    row(hw.isAppleSilicon, "Chip", "\(hw.chip) (\(hw.performanceCores)P/\(hw.totalCores) cores\(hw.gpuCores.map { ", \($0) GPU" } ?? ""))")
    row(hw.memoryGB >= 8, "Memory", String(format: "%.0f GB  tier: %@", hw.memoryGB, hw.tier.rawValue))
    row(hw.freeDiskGB >= 10, "Free disk", String(format: "%.1f GB", hw.freeDiskGB))
    row(nil, "macOS", hw.osVersion)

    print(Ansi.bold("\nRuntimes"))
    let fm = FileManager.default
    let ollama = which("ollama")
    row(ollama != nil, "ollama", ollama ?? "not found (brew install ollama)")
    let wcands = [Paths.bin.appendingPathComponent("whisper-server").path, which("whisper-server") ?? ""]
    let w = wcands.first { !$0.isEmpty && fm.isExecutableFile(atPath: $0) }
    row(w != nil, "whisper-server", w ?? "not installed")
    let py = Paths.venv.appendingPathComponent("bin/python").path
    row(fm.isExecutableFile(atPath: py), "piper venv", fm.isExecutableFile(atPath: py) ? Paths.venv.path : "not created")

    print(Ansi.bold("\nServices"))
    let o = await probe(Endpoints.ollama.appendingPathComponent("api/tags"))
    let s = await probe(Endpoints.whisper)
    let t = await probe(Endpoints.tts.appendingPathComponent("health"))
    row(o.ok, "Ollama LLM", "\(Endpoints.ollama.absoluteString)  \(o.detail)")
    row(s.ok, "Whisper STT", "\(Endpoints.whisper.absoluteString)  \(s.detail)")
    row(t.ok, "Piper TTS", "\(Endpoints.tts.absoluteString)  \(t.detail)")

    print(Ansi.bold("\nPorts"))
    for (n, p) in [("ollama", 11434), ("whisper", 18181), ("tts", 18182)] {
        let open = portOpen(UInt16(p))
        row(nil, "\(n) :\(p)", open ? "in use / listening" : "free")
    }

    print(Ansi.bold("\nMicrophone"))
    let st = AVCaptureDevice.authorizationStatus(for: .audio)
    let names: [AVAuthorizationStatus: String] = [.authorized: "authorized", .denied: "denied (System Settings › Privacy › Microphone)", .restricted: "restricted", .notDetermined: "not yet requested (granted on first `orb run`)"]
    row(st == .authorized ? true : (st == .notDetermined ? nil : false), "Permission", names[st] ?? "unknown")

    print(Ansi.bold("\nConfig"))
    let cfg = SetupEngine.loadConfig()
    if let cfg {
        row(cfg.setupCompleted, "Setup", cfg.setupCompleted ? "complete" : "incomplete — run `orb setup`")
        row(nil, "LLM / STT / TTS", "\(cfg.llm.name) / \(cfg.stt.name) / \(cfg.tts.name)")
    } else { row(false, "Setup", "no config — run `orb setup`") }
}

// MARK: models
@MainActor func cmdModels(_ args: [String]) async {
    guard let k = args.first, let kind = ModelKind(rawValue: k.lowercased()) else { fail("usage: orb models <stt|tts|llm> [query]") }
    let query = args.dropFirst().joined(separator: " ")
    let hw = await HardwareDetector().detect()
    let cat = ModelCatalog()
    var list: [CatalogModel]
    if query.isEmpty { list = await cat.featured(kind: kind, hardware: hw) }
    else {
        do { list = try await cat.search(kind: kind, query: query, hardware: hw) }
        catch { fail("search failed: \(error.localizedDescription)") }
    }
    let rec = await cat.recommended(kind: kind, hardware: hw)
    print(Ansi.bold(query.isEmpty ? "Featured \(kind.rawValue.uppercased()) models" : "\(kind.rawValue.uppercased()) models matching “\(query)”") + Ansi.dim("  (\(hw.chip), \(Int(hw.memoryGB)) GB)"))
    if list.isEmpty { print("  no results"); return }
    for m in list {
        let tag = m.compatibility == .verified ? Ansi.green("verified    ") : Ansi.yellow("experimental")
        let star = m.id == rec?.id ? Ansi.amber("★") : " "
        let fits = m.minMemoryGB <= hw.memoryGB ? "" : Ansi.red(" (needs \(Int(m.minMemoryGB)) GB)")
        let label = m.id.hasPrefix("\(kind.rawValue):") ? String(m.id.dropFirst(kind.rawValue.count + 1)) : m.id
        print("\(star) \(tag) \(pad(label, 44)) \(pad(m.quality, 9)) \(pad(fmtBytes(m.sizeBytes), 9))\(fits)")
        print(Ansi.dim("      \(m.name)\(m.summary.isEmpty ? "" : " — \(m.summary.prefix(80))")"))
    }
    print(Ansi.dim("\n★ recommended. Use the model id with `orb setup --\(kind.rawValue) <id>`."))
}

// MARK: shared selection
@MainActor func resolve(kind: ModelKind, key: String?, hw: HardwareProfile, cat: ModelCatalog) async -> CatalogModel {
    if let key, !key.isEmpty {
        // Local file path support for custom STT (.bin) or TTS (.onnx)
        let expanded = (key as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") || key.hasPrefix("./") || key.hasPrefix("../") || FileManager.default.fileExists(atPath: expanded) {
            let url = URL(fileURLWithPath: expanded)
            do {
                switch kind {
                case .stt: return try CompatibilityRegistry.customSTTFromLocalFile(url)
                case .tts: return try CompatibilityRegistry.customTTSFromLocalFile(url)
                case .llm: return CompatibilityRegistry.customLLMFromTag(key)
                }
            } catch {
                fail(error.localizedDescription)
            }
        }
        let feat = await cat.featured(kind: kind, hardware: hw)
        if let m = feat.first(where: { $0.id == key || $0.repoID == key || $0.id.hasSuffix(":" + key) || $0.id.hasSuffix("#" + key) || $0.name.lowercased() == key.lowercased() }) { return m }
        if let r = try? await cat.search(kind: kind, query: key, hardware: hw),
           let m = r.first(where: { $0.id == key || $0.repoID == key || $0.id.hasSuffix("#" + key) }) ?? r.first { return m }
        if kind == .llm { return CompatibilityRegistry.customLLMFromTag(key) }
        fail("could not find \(kind.rawValue) model '\(key)'. Pass a catalog id, Hugging Face repo, or local file path (.bin / .onnx).")
    }
    guard let m = await cat.recommended(kind: kind, hardware: hw) else { fail("no recommended \(kind.rawValue) model for this hardware") }
    return m
}

// MARK: use (hot-swap models)
@MainActor func cmdUse(_ args: [String]) async {
    let (f, _) = parseFlags(args)
    guard f["stt"] != nil || f["tts"] != nil || f["llm"] != nil else {
        fail("usage: orb use [--stt <id|repo|/path/to/model.bin>] [--tts <id|repo|/path/to/voice.onnx>] [--llm <tag>]")
    }
    var cfg = requireConfig()
    let hw = await HardwareDetector().detect()
    let cat = ModelCatalog()
    let engine = SetupEngine(hardware: HardwareDetector(), downloader: ModelDownloader())
    do {
        if let sttKey = f["stt"] {
            let m = await resolve(kind: .stt, key: sttKey, hw: hw, cat: cat)
            print("Switching STT → \(Ansi.bold(m.name)) (\(m.repoID))")
            try await engine.switchSTT(m, config: &cfg) { p in
                print("\r  ↓ \(p.fileName)  \(fmtBytes(p.bytesDone))/\(fmtBytes(p.bytesTotal))", terminator: "")
                fflush(stdout)
            }
            print("\n  \(Ansi.green("✓")) STT active: \(m.name)")
        }
        if let ttsKey = f["tts"] {
            let m = await resolve(kind: .tts, key: ttsKey, hw: hw, cat: cat)
            print("Switching TTS → \(Ansi.bold(m.name)) (\(m.repoID))")
            try await engine.switchTTS(m, config: &cfg) { p in
                print("\r  ↓ \(p.fileName)  \(fmtBytes(p.bytesDone))/\(fmtBytes(p.bytesTotal))", terminator: "")
                fflush(stdout)
            }
            print("\n  \(Ansi.green("✓")) TTS active: \(m.name)")
        }
        if let llmKey = f["llm"] {
            let m = await resolve(kind: .llm, key: llmKey, hw: hw, cat: cat)
            print("Switching LLM → \(Ansi.bold(m.name)) (\(m.repoID))")
            try await engine.switchLLM(m, config: &cfg) { p in
                print("\r  ↓ \(p.fileName)  \(fmtBytes(p.bytesDone))/\(fmtBytes(p.bytesTotal))", terminator: "")
                fflush(stdout)
            }
            print("\n  \(Ansi.green("✓")) LLM active: \(m.name)")
        }
    } catch {
        print("")
        fail(error.localizedDescription)
    }
}

// MARK: setup
@MainActor final class DoneFlag { var done = false }
@MainActor func cmdSetup(_ args: [String]) async {
    let (f, _) = parseFlags(args)
    let hw = await HardwareDetector().detect()
    let cat = ModelCatalog()
    let llm = await resolve(kind: .llm, key: f["llm"], hw: hw, cat: cat)
    let stt = await resolve(kind: .stt, key: f["stt"], hw: hw, cat: cat)
    let tts = await resolve(kind: .tts, key: f["tts"], hw: hw, cat: cat)
    var cfg = SetupEngine.loadConfig() ?? OrbConfig(llm: llm, stt: stt, tts: tts)
    cfg.llm = llm; cfg.stt = stt; cfg.tts = tts
    print("Hardware: \(hw.chip), \(Int(hw.memoryGB)) GB (\(hw.tier.rawValue))")
    print("  LLM \(llm.repoID)  STT \(stt.repoID)  TTS \(tts.repoID)")

    let engine = SetupEngine(hardware: HardwareDetector(), downloader: ModelDownloader())
    let ses = TerminalOrbSession()
    let flag = DoneFlag()
    let task = Task { @MainActor in await engine.run(config: cfg); flag.done = true }
    var cancelled = false
    var lastLogCount = 0, lastStep = ""
    let spin = Array("⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏")
    if ses.isTTY { ses.enter() }
    while true {
        if ses.interrupted && !cancelled { cancelled = true; engine.cancel() }
        let done = flag.done
        if ses.isTTY {
            var foot: [String] = []
            let n = engine.steps.count, d = engine.steps.filter { $0.status == .done || $0.status == .skipped }.count
            let marks = engine.steps.map { s -> String in
                switch s.status { case .done: return Ansi.green("●"); case .skipped: return Ansi.dim("○"); case .running: return Ansi.amber("◉"); case .failed: return Ansi.red("✗"); case .pending: return Ansi.dim("·") }
            }.joined(separator: " ")
            foot.append(" " + marks + Ansi.dim("  \(d)/\(n)"))
            let sp = String(spin[Int(ses.elapsed * 10) % spin.count])
            foot.append(" " + Ansi.amber(sp) + " " + Ansi.bold(engine.currentOperation) + (cancelled ? Ansi.yellow("  (cancelling…)") : ""))
            foot.append(" " + bar(engine.progress))
            if let dl = engine.downloadProgress {
                foot.append(" " + Ansi.dim("↓ \(dl.fileName)  \(fmtBytes(dl.bytesDone))/\(fmtBytes(dl.bytesTotal))  \(fmtBytes(Int64(dl.bytesPerSecond)))/s  ETA \(fmtETA(dl.etaSeconds))"))
            }
            if let e = engine.error { foot.append(" " + Ansi.red("✗ " + e)) }
            for l in engine.logs.suffix(4) { foot.append(Ansi.dim("   " + l)) }
            foot.append(Ansi.dim(" Ctrl-C to cancel"))
            ses.draw(state: engine.orbState, amplitude: 0, footer: foot)
            await ses.waitFrame()
        } else {
            let cur = engine.currentOperation
            if cur != lastStep { print("▸ \(cur)  \(Int(engine.progress * 100))%"); lastStep = cur }
            let lg = engine.logs
            if lg.count > lastLogCount { lg[lastLogCount...].forEach { print("  \($0)") }; lastLogCount = lg.count }
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        if done { break }
    }
    _ = await task.value
    if ses.isTTY {
        ses.draw(state: engine.orbState, amplitude: 0, footer: [])
        try? await Task.sleep(nanoseconds: 800_000_000)
        ses.leave()
    }
    print(Ansi.bold("\nSetup steps:"))
    for s in engine.steps {
        let m: String
        switch s.status { case .done: m = Ansi.green("✓"); case .failed: m = Ansi.red("✗"); case .skipped: m = Ansi.dim("-"); case .running: m = Ansi.yellow("…"); case .pending: m = Ansi.dim("·") }
        print("  \(m) \(s.title)\(s.detail.isEmpty ? "" : Ansi.dim("  " + s.detail))")
    }
    if let e = engine.error { fail(e) }
    if cancelled { print(Ansi.yellow("\nCancelled. Partial downloads are kept; re-run `orb setup` to resume.")); exit(130) }
    print(Ansi.green("\nORB is ready.") + " Try `orb run` or `orb chat`.")
}

// MARK: config helper
func requireConfig() -> OrbConfig {
    guard let c = SetupEngine.loadConfig() else { fail("no configuration found. Run `orb setup` first.") }
    return c
}

// MARK: run
@MainActor func cmdRun() async {
    let cfg = requireConfig()
    if !cfg.setupCompleted { print(Ansi.yellow("warning: setup not verified; run `orb setup` if things fail.")) }
    let setup = SetupEngine(hardware: HardwareDetector(), downloader: ModelDownloader())
    do { try await setup.startServices(config: cfg) }
    catch { fail("failed to start services: \(error.localizedDescription)") }
    let agent = VoiceAgent(config: cfg)
    let ses = TerminalOrbSession()
    await agent.start()
    var lastPrinted = ""
    if ses.isTTY { ses.enter() }
    while !ses.interrupted {
        let text = agent.transcript.map { ($0.role == .user ? "you › " : "orb › ") + $0.text }.joined(separator: "\n") + (agent.lastError.map { "\n! " + $0 } ?? "")
        if ses.isTTY {
            _ = ses.readKey()
            let lines = text.split(separator: "\n", omittingEmptySubsequences: true).suffix(6).map { " " + String($0) }
            ses.draw(state: agent.state, amplitude: Double(agent.level), footer: [Ansi.amber(" ● \(agent.state.rawValue)") + Ansi.dim("   Ctrl-C to quit")] + lines)
            await ses.waitFrame()
        } else {
            if text != lastPrinted { print(text.hasPrefix(lastPrinted) ? String(text.dropFirst(lastPrinted.count)).trimmingCharacters(in: .newlines) : text); lastPrinted = text }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
    }
    agent.stop()
    if ses.isTTY { ses.leave() }
    print("Bye.")
}

// MARK: chat
func ollamaChat(model: String, messages: [ChatMessage], onToken: (String) -> Void) async throws -> String {
    var req = URLRequest(url: Endpoints.ollama.appendingPathComponent("api/chat"))
    req.httpMethod = "POST"; req.timeoutInterval = 300
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    let body: [String: Any] = ["model": model, "stream": true, "messages": messages.map { ["role": $0.role, "content": $0.content] }]
    req.httpBody = try JSONSerialization.data(withJSONObject: body)
    let (bytes, resp) = try await URLSession.shared.bytes(for: req)
    if let h = resp as? HTTPURLResponse, h.statusCode != 200 { throw OrbError.message("Ollama returned HTTP \(h.statusCode) (is model '\(model)' pulled?)") }
    var full = ""
    for try await line in bytes.lines {
        guard let d = line.data(using: .utf8), let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { continue }
        if let m = j["message"] as? [String: Any], let c = m["content"] as? String { full += c; onToken(c) }
    }
    return full
}

@MainActor func cmdChat() async {
    let cfg = requireConfig()
    let setup = SetupEngine(hardware: HardwareDetector(), downloader: ModelDownloader())
    if !(await probe(Endpoints.ollama.appendingPathComponent("api/tags"))).ok {
        do { try await setup.startServices(config: cfg) }
        catch { fail("Ollama is not running at \(Endpoints.ollama.absoluteString) and could not be started: \(error.localizedDescription)") }
    }
    var msgs = [ChatMessage(role: "system", content: cfg.systemPrompt)]
    print(Ansi.amber("ORB chat") + Ansi.dim(" — model \(cfg.llm.repoID). Empty line or Ctrl-D to exit."))
    while true {
        print(Ansi.bold("you › "), terminator: ""); fflush(stdout)
        guard let line = readLine(), !line.trimmingCharacters(in: .whitespaces).isEmpty else { break }
        msgs.append(ChatMessage(role: "user", content: line))
        print(Ansi.amber("orb › "), terminator: "")
        do {
            let reply = try await ollamaChat(model: cfg.llm.repoID, messages: msgs) { print($0, terminator: ""); fflush(stdout) }
            print(""); msgs.append(ChatMessage(role: "assistant", content: reply))
        } catch { print(""); print(Ansi.red("error: \(error.localizedDescription)")); msgs.removeLast() }
    }
}

// MARK: status / stop
@MainActor func cmdStatus() async {
    let cfg = SetupEngine.loadConfig()
    print(Ansi.bold("ORB status"))
    if let cfg {
        print("  setup:  \(cfg.setupCompleted ? Ansi.green("complete") : Ansi.yellow("incomplete"))" + (cfg.lastVerifiedAt.map { Ansi.dim("  verified \($0)") } ?? ""))
        print("  LLM:    \(cfg.llm.repoID)\n  STT:    \(cfg.stt.repoID)\n  TTS:    \(cfg.tts.repoID)")
    } else { print("  setup:  \(Ansi.red("not configured")) — run `orb setup`") }
    for (n, u) in [("ollama", Endpoints.ollama.appendingPathComponent("api/tags")), ("whisper", Endpoints.whisper), ("tts", Endpoints.tts.appendingPathComponent("health"))] {
        let r = await probe(u)
        print("  \(pad(n, 8)) \(r.ok ? Ansi.green("up") : Ansi.red("down"))")
    }
}

@MainActor func cmdStop() {
    var stopped = 0
    for port in [18181, 18182] {
        for pid in shell("lsof -ti tcp:\(port) -sTCP:LISTEN").split(separator: "\n") {
            if let p = Int32(pid) { kill(p, SIGTERM); stopped += 1; print("stopped pid \(p) (port \(port))") }
        }
    }
    print(stopped == 0 ? "No ORB services running." : "Stopped \(stopped) service(s). (Ollama left running.)")
}
