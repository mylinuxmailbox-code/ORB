import SwiftUI
import OrbCore
import AppKit
import ServiceManagement

@MainActor
final class SettingsViewState: ObservableObject {
    @Published var modelsDir = UserDefaults.standard.string(forKey: "modelsDir") ?? Paths.models.path
    @Published var inputs = AudioDevices.inputs
    @Published var outputs = AudioDevices.outputs
    @Published var versions: [String: String] = [:]
    @Published var note: String?
}

struct SettingsView: View {
    @EnvironmentObject var m: AppModel
    @StateObject private var s = SettingsViewState()
    @StateObject var tester = DeviceTester()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                group("AUDIO DEVICES") {
                    HStack { lbl("INPUT"); Picker("", selection: dev(input: true)) {
                        Text("System default").tag(""); ForEach(s.inputs) { Text($0.name).tag($0.uid) } }.labelsHidden()
                        PixelButton(title: "TEST") { tester.testMic() } }
                    HStack { lbl("OUTPUT"); Picker("", selection: dev(input: false)) {
                        Text("System default").tag(""); ForEach(s.outputs) { Text($0.name).tag($0.uid) } }.labelsHidden()
                        PixelButton(title: "TEST") { tester.testSpeaker() } }
                    if let t = tester.message { Text(t).font(T.mono(10)).foregroundStyle(T.dim) }
                }
                group("MODELS") {
                    if let c = m.config {
                        kv("THINKING", "\(c.llm.name) · \(c.llm.repoID)")
                        kv("SPEECH TO TEXT", "\(c.stt.name) · \(c.stt.repoID)")
                        kv("TEXT TO SPEECH", "\(c.tts.name)\(c.tts.voice.map { " · " + $0 } ?? "")")
                    } else { Text("No configuration yet.").font(T.sans(12)).foregroundStyle(T.dim) }
                    PixelButton(title: "CHANGE MODELS…") { m.backToBuilder() }
                }
                group("MODELS DIRECTORY") {
                    Text(s.modelsDir).font(T.mono(11)).foregroundStyle(T.text).textSelection(.enabled)
                    HStack {
                        PixelButton(title: "CHOOSE…") { choose() }
                        PixelButton(title: "RESET") {
                            UserDefaults.standard.removeObject(forKey: "modelsDir"); Paths.override = nil; s.modelsDir = Paths.models.path }
                        PixelButton(title: "REVEAL") { NSWorkspace.shared.activateFileViewerSelecting([Paths.models]) }
                    }
                    Text("Existing models are not moved. Re-run setup to download into the new location.").font(T.sans(11)).foregroundStyle(T.dim)
                }
                group("STARTUP") {
                    Toggle("Launch at login", isOn: flag(\.launchAtLogin) { on in
                        do { if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } }
                        catch { s.note = "Launch at login unavailable: \(error.localizedDescription)" } })
                    Toggle("Start listening automatically", isOn: flag(\.autoStartAgent) { _ in })
                    if let n = s.note { Text(n).font(T.mono(10)).foregroundStyle(T.amber) }
                }
                group("HARDWARE & MEMORY") {
                    if let h = m.hardware {
                        kv("CHIP", h.chip); kv("CORES", "\(h.performanceCores)P / \(h.totalCores) total" + (h.gpuCores.map { " · \($0) GPU" } ?? ""))
                        kv("MEMORY", "\(Int(h.memoryGB)) GB · tier \(h.tier.rawValue)"); kv("OS", h.osVersion)
                        kv("FREE DISK", String(format: "%.0f GB", h.freeDiskGB))
                    }
                }
                group("DIAGNOSTICS") {
                    kv("OLLAMA", status(m.health.ollama) + (s.versions["ollama"].map { " · " + $0 } ?? ""))
                    kv("WHISPER", status(m.health.whisper) + (s.versions["whisper"].map { " · " + $0 } ?? ""))
                    kv("PIPER TTS", status(m.health.tts) + (s.versions["piper"].map { " · " + $0 } ?? ""))
                    let inst = RuntimeInstaller()
                    kv("OLLAMA BIN", inst.ollamaPath()?.path ?? "not found")
                    kv("WHISPER BIN", inst.whisperServerPath()?.path ?? "not found")
                    kv("PIPER", inst.piperImportable() ? "installed in venv" : "not installed")
                    PixelButton(title: "REFRESH") { Task { await m.refreshHealth(); await loadVersions() } }
                }
                group("ADVANCED") {
                    kv("DATA", Paths.root.path); kv("LOGS", Paths.logs.path)
                    kv("PORTS", "11434 · 18181 · 18182")
                    HStack {
                        PixelButton(title: "OPEN LOGS") { NSWorkspace.shared.open(Paths.logs) }
                        PixelButton(title: "STOP SERVICES") { Task { await m.setup.stopServices(); await m.refreshHealth() } }
                    }
                }
            }.padding(28).frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: 600, height: 700).background(T.bg).foregroundStyle(T.text)
        .tint(T.amber)
        .task { await loadVersions() }
    }

    func status(_ ok: Bool) -> String { ok ? "healthy" : "not responding" }
    func lbl(_ s: String) -> some View { Text(s).font(T.mono(10)).foregroundStyle(T.dim).frame(width: 60, alignment: .leading) }
    func kv(_ k: String, _ v: String) -> some View {
        HStack(alignment: .top) { Text(k).font(T.mono(10)).foregroundStyle(T.dim).frame(width: 110, alignment: .leading)
            Text(v).font(T.mono(11)).textSelection(.enabled) }
    }
    func group<C: View>(_ title: String, @ViewBuilder _ c: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(T.mono(11, .bold)).tracking(1.5).foregroundStyle(T.amber)
            c()
        }.padding(.top, 10).frame(maxWidth: .infinity, alignment: .leading).overlay(alignment: .top) { Rectangle().fill(T.line).frame(height: 1) }
    }
    func dev(input: Bool) -> Binding<String> {
        Binding(get: { (input ? m.config?.inputDeviceUID : m.config?.outputDeviceUID) ?? "" }, set: { uid in
            guard var c = m.config else { return }
            if input { c.inputDeviceUID = uid.isEmpty ? nil : uid } else { c.outputDeviceUID = uid.isEmpty ? nil : uid }
            m.saveConfig(c) })
    }
    func flag(_ kp: WritableKeyPath<OrbConfig, Bool>, _ side: @escaping (Bool) -> Void) -> Binding<Bool> {
        Binding(get: { m.config?[keyPath: kp] ?? false }, set: { v in
            guard var c = m.config else { return }
            c[keyPath: kp] = v; m.saveConfig(c); side(v) })
    }
    func choose() {
        let p = NSOpenPanel(); p.canChooseDirectories = true; p.canChooseFiles = false; p.canCreateDirectories = true
        p.prompt = "Use as models directory"
        if p.runModal() == .OK, let u = p.url {
            UserDefaults.standard.set(u.path, forKey: "modelsDir"); Paths.override = u; s.modelsDir = u.path
        }
    }
    func loadVersions() async {
        func ver(_ exe: URL?, _ args: [String]) async -> String? {
            guard let exe else { return nil }
            let r = try? await Shell.run(exe.path, args)
            return r?.output.split(separator: "\n").first.map(String.init)
        }
        let i = RuntimeInstaller()
        if let v = await ver(i.ollamaPath(), ["--version"]) { s.versions["ollama"] = v }
        if let v = await ver(i.venvPython, ["-c", "import importlib.metadata as m;print('piper-tts '+m.version('piper-tts'))"]) { s.versions["piper"] = v }
    }
}
