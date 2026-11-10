import SwiftUI
import AppKit
import OrbCore

@MainActor
final class BuilderModel: ObservableObject {
    @Published var featured: [ModelKind: [CatalogModel]] = [:]
    @Published var selected: [ModelKind: CatalogModel] = [:]
    @Published var systemPrompt = OrbConfig(llm: placeholder, stt: placeholder, tts: placeholder).systemPrompt
    @Published var loading = true
    @Published var advanced = false
    @Published var browse: ModelKind?
    @Published var customErr: String?

    static let placeholder = CatalogModel(id: "x", kind: .llm, name: "", repoID: "", backend: .ollama)

    func load(_ m: AppModel) async {
        guard let hw = m.hardware else { return }
        for k in ModelKind.allCases {
            var list = await m.catalog.featured(kind: k, hardware: hw)
            let rec = await m.catalog.recommended(kind: k, hardware: hw)
            if let rec, !list.contains(where: { $0.id == rec.id }) { list.insert(rec, at: 0) }
            featured[k] = list
            if selected[k] == nil { selected[k] = rec ?? list.first }
        }
        if let cfg = m.config {
            for (k, mod) in [(ModelKind.llm, cfg.llm), (.stt, cfg.stt), (.tts, cfg.tts)] {
                if !(featured[k] ?? []).contains(where: { $0.id == mod.id }) { featured[k, default: []].insert(mod, at: 0) }
                selected[k] = mod
            }
            systemPrompt = cfg.systemPrompt
        }
        loading = false
    }

    func build(_ m: AppModel) -> OrbConfig? {
        guard let l = selected[.llm], let s = selected[.stt], let t = selected[.tts] else { return nil }
        var c = m.config ?? OrbConfig(llm: l, stt: s, tts: t)
        c.llm = l; c.stt = s; c.tts = t; c.systemPrompt = systemPrompt
        c.setupCompleted = false
        return c
    }
}

struct BuilderView: View {
    @EnvironmentObject var m: AppModel
    @StateObject private var b = BuilderModel()

    var body: some View {
        VStack(spacing: 0) {
            HeaderBar()
            ScrollView {
                VStack(spacing: 22) {
                    OrbView(state: .idle).frame(width: 220, height: 220).padding(.top, 8)
                    VStack(spacing: 6) {
                        Text("Build your voice agent.").font(T.sans(30, .semibold)).foregroundStyle(T.text)
                        Text("Three models. One local AI.").font(T.mono(13)).foregroundStyle(T.dim)
                    }
                    if b.loading {
                        ProgressView().controlSize(.small).tint(T.amber).padding(30)
                    } else {
                        VStack(spacing: 0) {
                            section(1, "THINKING MODEL", .llm)
                            section(2, "SPEECH TO TEXT", .stt)
                            section(3, "TEXT TO SPEECH", .tts)
                        }.frame(maxWidth: 640)
                        advancedSection.frame(maxWidth: 640)
                        PixelButton(title: "SET UP MY ORB →", primary: true, disabled: b.selected.count < 3) {
                            if let c = b.build(m) { m.beginSetup(c) }
                        }.padding(.vertical, 8)
                        if let hw = m.hardware {
                            Text("\(hw.chip) · \(Int(hw.memoryGB)) GB · \(hw.tier.rawValue.uppercased()) tier · \(Int(hw.freeDiskGB)) GB free")
                                .font(T.mono(10)).foregroundStyle(T.dim)
                        }
                    }
                }.padding(.bottom, 40).frame(maxWidth: .infinity)
            }
        }
        .task { await b.load(m) }
        .sheet(item: Binding(get: { b.browse.map { KindBox(kind: $0) } }, set: { b.browse = $0?.kind })) { box in
            HFBrowserSheet(kind: box.kind) { chosen in
                if !(b.featured[box.kind] ?? []).contains(where: { $0.id == chosen.id }) { b.featured[box.kind, default: []].insert(chosen, at: 0) }
                b.selected[box.kind] = chosen
            }.environmentObject(m)
        }
    }

    func section(_ n: Int, _ title: String, _ kind: ModelKind) -> some View {
        let list = b.featured[kind] ?? []
        let sel = b.selected[kind]
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                Text("0\(n) — \(title)").font(T.mono(12, .bold)).tracking(1.5).foregroundStyle(T.amber)
                Spacer()
                if kind == .stt || kind == .tts {
                    Button("+ IMPORT LOCAL FILE…") { pickLocalFile(kind) }
                        .buttonStyle(.plain).font(T.mono(10, .medium)).foregroundStyle(T.amber)
                }
                Button(kind == .llm ? "CUSTOM TAG / BROWSE" : "BROWSE HUGGING FACE") { b.browse = kind }
                    .buttonStyle(.plain).font(T.mono(10, .medium)).foregroundStyle(T.dim)
            }
            Picker("", selection: Binding(get: { sel?.id ?? "" }, set: { id in b.selected[kind] = list.first { $0.id == id } })) {
                ForEach(list) { Text($0.name).tag($0.id) }
            }.labelsHidden().pickerStyle(.menu)
            if let s = sel { ModelDetail(model: s, memoryGB: m.hardware?.memoryGB) }
            if let err = b.customErr { Text(err).font(T.mono(10)).foregroundStyle(T.red) }
        }
        .padding(.vertical, 16)
        .overlay(alignment: .top) { Rectangle().fill(T.line).frame(height: 1) }
    }

    func pickLocalFile(_ kind: ModelKind) {
        b.customErr = nil
        let p = NSOpenPanel()
        p.canChooseFiles = true; p.canChooseDirectories = false; p.allowsMultipleSelection = false
        p.message = kind == .stt ? "Choose a whisper.cpp ggml .bin model file" : "Choose a Piper .onnx voice model (with matching .onnx.json in the same folder)"
        p.prompt = "Use Model"
        if p.runModal() == .OK, let u = p.url {
            do {
                let custom = kind == .stt ? try CompatibilityRegistry.customSTTFromLocalFile(u) : try CompatibilityRegistry.customTTSFromLocalFile(u)
                if !(b.featured[kind] ?? []).contains(where: { $0.id == custom.id }) {
                    b.featured[kind, default: []].insert(custom, at: 0)
                }
                b.selected[kind] = custom
            } catch {
                b.customErr = error.localizedDescription
            }
        }
    }

    var advancedSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button { withAnimation { b.advanced.toggle() } } label: {
                HStack { Text(b.advanced ? "▾ ADVANCED" : "▸ ADVANCED").font(T.mono(11, .medium)).tracking(1.2); Spacer() }
                    .foregroundStyle(T.dim).contentShape(Rectangle())
            }.buttonStyle(.plain)
            if b.advanced {
                Text("SYSTEM PROMPT").font(T.mono(10)).foregroundStyle(T.dim)
                TextEditor(text: $b.systemPrompt).font(T.mono(12)).scrollContentBackground(.hidden)
                    .frame(height: 80).padding(6).background(T.panel).overlay(Rectangle().stroke(T.line))
                row("MODELS DIR", Paths.models.path)
                row("OLLAMA", Endpoints.ollama.absoluteString)
                row("WHISPER STT", Endpoints.whisper.absoluteString)
                row("PIPER TTS", Endpoints.tts.absoluteString)
            }
        }.padding(.vertical, 12).overlay(alignment: .top) { Rectangle().fill(T.line).frame(height: 1) }
    }
    func row(_ k: String, _ v: String) -> some View {
        HStack { Text(k).font(T.mono(10)).foregroundStyle(T.dim).frame(width: 100, alignment: .leading)
            Text(v).font(T.mono(11)).foregroundStyle(T.text).textSelection(.enabled) }
    }
}

struct KindBox: Identifiable { let kind: ModelKind; var id: String { kind.rawValue } }

struct ModelDetail: View {
    let model: CatalogModel; var memoryGB: Double?
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(model.name).font(T.sans(15, .medium)).foregroundStyle(T.text)
                CompatBadge(c: model.compatibility)
                if let mem = memoryGB, model.minMemoryGB > mem { Tag(text: "NEEDS \(Int(model.minMemoryGB)) GB RAM", color: T.red) }
            }
            Text("\(model.repoID) · \(fmtBytes(model.sizeBytes)) · \(model.languages.prefix(6).joined(separator: ", ")) · \(model.license ?? "license n/a") · \(model.quality)")
                .font(T.mono(11)).foregroundStyle(T.dim)
            if !model.summary.isEmpty { Text(model.summary).font(T.sans(12)).foregroundStyle(T.dim) }
            if model.compatibility == .experimental {
                Text("Experimental: heuristically matched, may not run. Setup will verify it end to end.")
                    .font(T.sans(11)).foregroundStyle(T.amber.opacity(0.8))
            }
        }
    }
}

@MainActor
final class HFBrowserState: ObservableObject {
    @Published var query = ""
    @Published var results: [CatalogModel] = []
    @Published var busy = false
    @Published var err: String?
    var task: Task<Void, Never>?
}

struct HFBrowserSheet: View {
    let kind: ModelKind; let onPick: (CatalogModel) -> Void
    @EnvironmentObject var m: AppModel
    @Environment(\.dismiss) var dismiss
    @StateObject private var s = HFBrowserState()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("CHOOSE \(kind.rawValue.uppercased()) MODEL · HUGGING FACE / CUSTOM").font(T.mono(12, .bold)).tracking(1.5).foregroundStyle(T.amber)
                Spacer()
                if kind == .stt || kind == .tts {
                    PixelButton(title: "+ IMPORT LOCAL FILE…") { importLocal() }
                }
                Button("CLOSE") { dismiss() }.buttonStyle(.plain).font(T.mono(11)).foregroundStyle(T.dim).padding(.leading, 8)
            }
            HStack {
                TextField(kind == .llm ? "Search or enter any Ollama tag (e.g. deepseek-r1:8b, hf.co/…)…" : "Search Hugging Face or enter owner/repo (e.g. ggerganov/whisper.cpp)…", text: $s.query)
                    .textFieldStyle(.plain).font(T.mono(13))
                    .padding(8).background(T.panel).overlay(Rectangle().stroke(T.line))
                    .onChange(of: s.query) { _, _ in schedule() }
                if kind == .llm && !s.query.trimmingCharacters(in: .whitespaces).isEmpty {
                    PixelButton(title: "USE TAG") {
                        onPick(CompatibilityRegistry.customLLMFromTag(s.query))
                        dismiss()
                    }
                }
            }
            if let err = s.err { Text(err).font(T.mono(11)).foregroundStyle(T.red) }
            if s.busy { ProgressView().controlSize(.small) }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(s.results) { r in
                        Button { onPick(r); dismiss() } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack { Text(r.name).font(T.sans(13, .medium)); CompatBadge(c: r.compatibility); Spacer()
                                    Text(fmtBytes(r.sizeBytes)).font(T.mono(11)).foregroundStyle(T.dim) }
                                Text("\(r.repoID) · \(r.license ?? "n/a") · ↓\(r.downloads ?? 0) ♥\(r.likes ?? 0) · \(r.languages.prefix(4).joined(separator: ","))")
                                    .font(T.mono(10)).foregroundStyle(T.dim)
                            }.padding(.vertical, 8).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                        }.buttonStyle(.plain).foregroundStyle(T.text)
                        Divider().overlay(T.line)
                    }
                }
            }
        }
        .padding(20).frame(width: 640, height: 520).background(T.bg).preferredColorScheme(.dark)
        .onAppear { schedule() }
    }

    func importLocal() {
        let p = NSOpenPanel()
        p.canChooseFiles = true; p.canChooseDirectories = false; p.allowsMultipleSelection = false
        p.message = kind == .stt ? "Choose a whisper.cpp ggml .bin model file" : "Choose a Piper .onnx voice model (with matching .onnx.json in the same folder)"
        p.prompt = "Use Model"
        if p.runModal() == .OK, let u = p.url {
            do {
                let custom = kind == .stt ? try CompatibilityRegistry.customSTTFromLocalFile(u) : try CompatibilityRegistry.customTTSFromLocalFile(u)
                onPick(custom)
                dismiss()
            } catch {
                s.err = error.localizedDescription
            }
        }
    }

    func schedule() {
        s.task?.cancel()
        s.task = Task {
            try? await Task.sleep(nanoseconds: 350_000_000)
            if Task.isCancelled { return }
            guard let hw = m.hardware else { return }
            s.busy = true; defer { s.busy = false }
            do { let r = try await m.catalog.search(kind: kind, query: s.query, hardware: hw)
                if !Task.isCancelled { s.results = r; s.err = nil } }
            catch { if !Task.isCancelled { s.err = "Search failed: \(error.localizedDescription)" } }
        }
    }
}
