import SwiftUI
import OrbCore
import AVFoundation
import AppKit

struct VoiceView: View {
    @EnvironmentObject var m: AppModel
    var body: some View {
        if let agent = m.agent { VoiceContent(agent: agent) } else { Color.clear }
    }
}

@MainActor
final class VoiceViewState: ObservableObject {
    @Published var text = ""
    @Published var listening = false
    @Published var inputs = AudioDevices.inputs
    @Published var outputs = AudioDevices.outputs
    @Published var llmChoices: [CatalogModel] = []
    @Published var sttChoices: [CatalogModel] = []
    @Published var ttsChoices: [CatalogModel] = []
    @Published var browseKind: ModelKind?
}

struct VoiceContent: View {
    @ObservedObject var agent: VoiceAgent
    @EnvironmentObject var m: AppModel
    @StateObject private var ui = VoiceViewState()
    @StateObject var tester = DeviceTester()

    var body: some View {
        VStack(spacing: 0) {
            HeaderBar()
            VStack(spacing: 14) {
                OrbView(state: agent.state, amplitude: Double(agent.level)).frame(width: 240, height: 240)
                Text(label).font(T.mono(12, .bold)).tracking(3).foregroundStyle(T.amber)
                if let e = agent.lastError { Text(e).font(T.mono(11)).foregroundStyle(T.red).multilineTextAlignment(.center).padding(.horizontal, 40) }
                HStack(spacing: 12) {
                    PixelButton(title: ui.listening ? "■ STOP LISTENING" : "● START LISTENING", primary: true) { toggle() }
                    PixelButton(title: "INTERRUPT", disabled: agent.state != .speaking && agent.state != .thinking) { agent.interrupt() }
                }
            }.padding(.top, 6)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(agent.transcript) { t in
                            HStack(alignment: .top, spacing: 10) {
                                Text(t.role == .user ? "YOU" : "ORB").font(T.mono(10, .bold))
                                    .foregroundStyle(t.role == .user ? T.dim : T.amber).frame(width: 34, alignment: .leading)
                                Text(t.text).font(T.sans(14)).foregroundStyle(T.text).textSelection(.enabled)
                            }.id(t.id)
                        }
                    }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: agent.transcript.count) { _, _ in if let l = agent.transcript.last { proxy.scrollTo(l.id) } }
                .onChange(of: agent.transcript.last?.text) { _, _ in if let l = agent.transcript.last { proxy.scrollTo(l.id) } }
            }
            .frame(maxWidth: 640).overlay(Rectangle().stroke(T.line)).padding(.horizontal, 28).padding(.top, 12)
            HStack {
                TextField("Type a message…", text: $ui.text).textFieldStyle(.plain).font(T.mono(12))
                    .padding(8).background(T.panel).overlay(Rectangle().stroke(T.line))
                    .onSubmit { send() }
                PixelButton(title: "SEND") { send() }
            }.frame(maxWidth: 640).padding(.horizontal, 28).padding(.top, 8)
            controls.frame(maxWidth: 640).padding(.horizontal, 28).padding(.vertical, 14)
        }
        .task {
            if let hw = m.hardware {
                ui.llmChoices = await m.catalog.featured(kind: .llm, hardware: hw)
                ui.sttChoices = await m.catalog.featured(kind: .stt, hardware: hw)
                ui.ttsChoices = await m.catalog.featured(kind: .tts, hardware: hw)
            }
            if let cur = m.config?.llm, !ui.llmChoices.contains(where: { $0.repoID == cur.repoID }) { ui.llmChoices.insert(cur, at: 0) }
            if let cur = m.config?.stt, !ui.sttChoices.contains(where: { $0.id == cur.id }) { ui.sttChoices.insert(cur, at: 0) }
            if let cur = m.config?.tts, !ui.ttsChoices.contains(where: { $0.id == cur.id }) { ui.ttsChoices.insert(cur, at: 0) }
        }
        .sheet(item: Binding(get: { ui.browseKind.map { KindBox(kind: $0) } }, set: { ui.browseKind = $0?.kind })) { box in
            HFBrowserSheet(kind: box.kind) { chosen in
                switch box.kind {
                case .llm: if !ui.llmChoices.contains(where: { $0.repoID == chosen.repoID }) { ui.llmChoices.insert(chosen, at: 0) }
                case .stt: if !ui.sttChoices.contains(where: { $0.id == chosen.id }) { ui.sttChoices.insert(chosen, at: 0) }
                case .tts: if !ui.ttsChoices.contains(where: { $0.id == chosen.id }) { ui.ttsChoices.insert(chosen, at: 0) }
                }
                m.hotSwapModel(chosen)
            }.environmentObject(m)
        }
    }

    var label: String {
        if !ui.listening && (agent.state == .idle || agent.state == .ready) { return "PAUSED" }
        return agent.state.rawValue.uppercased()
    }

    func toggle() {
        if ui.listening { agent.stop(); ui.listening = false }
        else { ui.listening = true; Task { await agent.start() } }
    }
    func send() { let t = ui.text.trimmingCharacters(in: .whitespaces); guard !t.isEmpty else { return }; ui.text = ""; agent.sendText(t) }

    var controls: some View {
        VStack(spacing: 8) {
            if let status = m.switchingStatus {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.mini).tint(T.amber)
                    Text(status).font(T.mono(10, .medium)).foregroundStyle(T.amber)
                    if let d = m.setup.downloadProgress {
                        Text("\(fmtBytes(d.bytesDone))/\(fmtBytes(d.bytesTotal))").font(T.mono(10)).foregroundStyle(T.dim)
                    }
                    Spacer()
                }
            }
            if let swErr = m.switchingError {
                Text("Swap failed: \(swErr)").font(T.mono(10)).foregroundStyle(T.red)
            }
            HStack {
                Text("LLM").font(T.mono(10)).foregroundStyle(T.dim).frame(width: 52, alignment: .leading)
                Picker("", selection: Binding(get: { agent.llmTag }, set: { tag in
                    if let mod = ui.llmChoices.first(where: { $0.repoID == tag }) { m.hotSwapModel(mod) }
                    else { agent.switchModel(tag) }
                })) {
                    ForEach(ui.llmChoices) { Text($0.name).tag($0.repoID) }
                }.labelsHidden()
                PixelButton(title: "CUSTOM…") { ui.browseKind = .llm }
            }
            HStack {
                Text("STT").font(T.mono(10)).foregroundStyle(T.dim).frame(width: 52, alignment: .leading)
                Picker("", selection: Binding(get: { m.config?.stt.id ?? "" }, set: { id in
                    if let mod = ui.sttChoices.first(where: { $0.id == id }) { m.hotSwapModel(mod) }
                })) {
                    ForEach(ui.sttChoices) { Text($0.name).tag($0.id) }
                }.labelsHidden()
                PixelButton(title: "HF / LOCAL…") { ui.browseKind = .stt }
            }
            HStack {
                Text("TTS").font(T.mono(10)).foregroundStyle(T.dim).frame(width: 52, alignment: .leading)
                Picker("", selection: Binding(get: { m.config?.tts.id ?? "" }, set: { id in
                    if let mod = ui.ttsChoices.first(where: { $0.id == id }) { m.hotSwapModel(mod) }
                })) {
                    ForEach(ui.ttsChoices) { Text($0.name).tag($0.id) }
                }.labelsHidden()
                PixelButton(title: "HF / LOCAL…") { ui.browseKind = .tts }
            }
            HStack {
                Text("MIC").font(T.mono(10)).foregroundStyle(T.dim).frame(width: 52, alignment: .leading)
                Picker("", selection: Binding(get: { m.config?.inputDeviceUID ?? "" }, set: { setDevice(input: true, $0) })) {
                    Text("System default").tag(""); ForEach(ui.inputs) { Text($0.name).tag($0.uid) }
                }.labelsHidden()
                PixelButton(title: "TEST") { tester.testMic() }
            }
            HStack {
                Text("SPEAKER").font(T.mono(10)).foregroundStyle(T.dim).frame(width: 52, alignment: .leading)
                Picker("", selection: Binding(get: { m.config?.outputDeviceUID ?? "" }, set: { setDevice(input: false, $0) })) {
                    Text("System default").tag(""); ForEach(ui.outputs) { Text($0.name).tag($0.uid) }
                }.labelsHidden()
                PixelButton(title: "TEST") { tester.testSpeaker() }
            }
            if let l = tester.message { Text(l).font(T.mono(10)).foregroundStyle(T.dim) }
        }
    }

    func setDevice(input: Bool, _ uid: String) {
        guard var c = m.config else { return }
        if input { c.inputDeviceUID = uid.isEmpty ? nil : uid } else { c.outputDeviceUID = uid.isEmpty ? nil : uid }
        m.saveConfig(c)
        if ui.listening { agent.stop(); m.agent = VoiceAgent(config: c); ui.listening = false }
    }
}

/// Mic level check and speaker beep.
@MainActor
final class DeviceTester: ObservableObject {
    @Published var message: String?
    private var engine: AVAudioEngine?
    private var player: NSSound?

    func testMic() {
        AVCaptureDevice.requestAccess(for: .audio) { ok in
            DispatchQueue.main.async {
                guard ok else { self.message = "Microphone access denied — enable it in System Settings."; return }
                let e = AVAudioEngine()
                var peak: Float = 0
                let fmt = e.inputNode.outputFormat(forBus: 0)
                e.inputNode.installTap(onBus: 0, bufferSize: 2048, format: fmt) { buf, _ in
                    guard let d = buf.floatChannelData?[0] else { return }
                    for i in 0..<Int(buf.frameLength) { peak = max(peak, abs(d[i])) }
                }
                do { try e.start() } catch { self.message = "Mic failed: \(error.localizedDescription)"; return }
                self.engine = e; self.message = "Listening for 2 s — speak now…"
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    e.inputNode.removeTap(onBus: 0); e.stop(); self.engine = nil
                    self.message = peak > 0.02 ? String(format: "Mic OK (peak %.2f)", peak) : "No signal detected."
                }
            }
        }
    }
    func testSpeaker() {
        player = NSSound(named: "Glass"); player?.play(); message = "Playing test sound…"
    }
}
