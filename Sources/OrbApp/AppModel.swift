import SwiftUI
import OrbCore

enum Screen { case booting, builder, setup, voice }

struct ServiceHealth: Equatable {
    var ollama = false, whisper = false, tts = false
    var all: Bool { ollama && whisper && tts }
    var any: Bool { ollama || whisper || tts }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var screen: Screen = .booting
    @Published var hardware: HardwareProfile?
    @Published var health = ServiceHealth()
    @Published var config: OrbConfig?
    @Published var agent: VoiceAgent?
    @Published var setupFailedMessage: String?
    @Published var switchingStatus: String?
    @Published var switchingError: String?

    let catalog = ModelCatalog()
    let downloader = ModelDownloader()
    let hwDetector = HardwareDetector()
    lazy var setup = SetupEngine(hardware: hwDetector, downloader: downloader)
    private var timer: Timer?

    func boot() async {
        guard screen == .booting else { return }
        hardware = await hwDetector.detect()
        startHealthPolling()
        if let cfg = SetupEngine.loadConfig(), cfg.setupCompleted {
            config = cfg
            await refreshHealth()
            if !health.all { try? await setup.startServices(config: cfg); await refreshHealth() }
            if health.all { enterVoice(cfg); return }
        }
        screen = .builder
    }

    func enterVoice(_ cfg: OrbConfig) {
        config = cfg
        agent = VoiceAgent(config: cfg)
        withAnimation(.easeInOut(duration: 0.4)) { screen = .voice }
        if cfg.autoStartAgent { Task { await agent?.start() } }
    }

    func beginSetup(_ cfg: OrbConfig) {
        config = cfg
        withAnimation(.easeInOut(duration: 0.4)) { screen = .setup }
        Task {
            await setup.run(config: cfg)
            if setup.error == nil, let c = SetupEngine.loadConfig(), c.setupCompleted {
                await refreshHealth()
                enterVoice(c)
            }
        }
    }

    func backToBuilder() {
        agent?.stop(); agent = nil
        withAnimation(.easeInOut(duration: 0.4)) { screen = .builder }
    }

    func saveConfig(_ cfg: OrbConfig) {
        config = cfg
        try? SetupEngine.saveConfig(cfg)
    }

    func hotSwapModel(_ model: CatalogModel) {
        guard var cfg = config else { return }
        switchingError = nil
        switchingStatus = "Switching \(model.kind.rawValue.uppercased()) to \(model.name)…"
        Task {
            do {
                switch model.kind {
                case .stt:
                    try await setup.switchSTT(model, config: &cfg)
                    agent?.updateSTT(model)
                case .tts:
                    try await setup.switchTTS(model, config: &cfg)
                    agent?.updateTTS(model)
                case .llm:
                    try await setup.switchLLM(model, config: &cfg)
                    agent?.switchModel(model.repoID)
                }
                config = cfg
                await refreshHealth()
                switchingStatus = nil
            } catch {
                switchingStatus = nil
                switchingError = error.localizedDescription
            }
        }
    }

    func startHealthPolling() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refreshHealth() }
        }
    }

    func refreshHealth() async {
        async let o = Self.ping(Endpoints.ollama.appendingPathComponent("api/tags"))
        async let w = Self.ping(Endpoints.whisper)
        async let t = Self.ping(Endpoints.tts.appendingPathComponent("health"))
        let h = ServiceHealth(ollama: await o, whisper: await w, tts: await t)
        if h != health { health = h }
    }

    nonisolated static func ping(_ url: URL) async -> Bool {
        var r = URLRequest(url: url); r.timeoutInterval = 1.5
        guard let (_, resp) = try? await URLSession.shared.data(for: r) else { return false }
        return (resp as? HTTPURLResponse) != nil
    }
}

struct RootView: View {
    @EnvironmentObject var m: AppModel
    var body: some View {
        ZStack {
            T.bg.ignoresSafeArea()
            switch m.screen {
            case .booting: ProgressView().controlSize(.small).tint(T.amber)
            case .builder: BuilderView().transition(.opacity.combined(with: .scale(scale: 0.98)))
            case .setup: SetupView().transition(.opacity.combined(with: .scale(scale: 0.98)))
            case .voice: VoiceView().transition(.opacity.combined(with: .scale(scale: 0.98)))
            }
        }
    }
}

struct HeaderBar: View {
    @EnvironmentObject var m: AppModel
    var body: some View {
        HStack {
            Text("ORB").font(T.mono(18, .bold)).tracking(6).foregroundStyle(T.text)
            Spacer()
            let ok = m.health.all
            HStack(spacing: 6) {
                Rectangle().fill(ok ? T.green : (m.health.any ? T.amber : T.dim)).frame(width: 7, height: 7)
                Text(ok ? "LOCAL · OFFLINE" : (m.health.any ? "LOCAL · DEGRADED" : "LOCAL · IDLE"))
                    .font(T.mono(10, .medium)).tracking(1).foregroundStyle(T.text)
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .overlay(Rectangle().stroke(T.line))
            Button { NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) } label: {
                Image(systemName: "gearshape").foregroundStyle(T.dim)
            }.buttonStyle(.plain).padding(.leading, 8)
        }
        .padding(.horizontal, 28).padding(.top, 14)
    }
}
