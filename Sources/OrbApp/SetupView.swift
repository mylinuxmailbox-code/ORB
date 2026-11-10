import SwiftUI
import OrbCore

struct SetupView: View {
    @EnvironmentObject var m: AppModel
    var body: some View { SetupContent(engine: m.setup) }
}

@MainActor
final class SetupViewState: ObservableObject {
    @Published var showLogs = false
}

struct SetupContent: View {
    @ObservedObject var engine: SetupEngine
    @EnvironmentObject var m: AppModel
    @StateObject private var ui = SetupViewState()

    var body: some View {
        VStack(spacing: 0) {
            HeaderBar()
            ScrollView {
                VStack(spacing: 18) {
                    OrbView(state: engine.error != nil ? .error : engine.orbState).frame(width: 200, height: 200)
                    Text(engine.error != nil ? "SETUP FAILED" : engine.currentOperation.uppercased())
                        .font(T.mono(12, .bold)).tracking(2).foregroundStyle(engine.error != nil ? T.red : T.amber)
                        .multilineTextAlignment(.center)
                    VStack(spacing: 6) {
                        GeometryReader { g in
                            ZStack(alignment: .leading) {
                                Rectangle().fill(T.line)
                                Rectangle().fill(engine.error != nil ? T.red : T.amber)
                                    .frame(width: g.size.width * CGFloat(min(max(engine.progress, 0), 1)))
                            }
                        }.frame(height: 6)
                        HStack {
                            Text("\(Int(engine.progress * 100))%").font(T.mono(11)).foregroundStyle(T.text)
                            Spacer()
                            if let d = engine.downloadProgress {
                                Text("\(d.fileName) · \(fmtBytes(d.bytesDone)) / \(fmtBytes(d.bytesTotal)) · \(fmtBytes(Int64(d.bytesPerSecond)))/s · ETA \(fmtETA(d.etaSeconds))")
                                    .font(T.mono(10)).foregroundStyle(T.dim).lineLimit(1)
                            }
                        }
                    }.frame(maxWidth: 560)

                    if let err = engine.error {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(err).font(T.mono(11)).foregroundStyle(T.red).textSelection(.enabled)
                            Text("Nothing is marked ready. Check the log below, then retry — partial downloads resume.")
                                .font(T.sans(12)).foregroundStyle(T.dim)
                        }.padding(12).frame(maxWidth: 560, alignment: .leading).overlay(Rectangle().stroke(T.red.opacity(0.6)))
                    }

                    VStack(spacing: 0) {
                        ForEach(engine.steps) { s in
                            HStack(alignment: .top, spacing: 10) {
                                icon(s.status).frame(width: 16)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(s.title).font(T.mono(12)).foregroundStyle(s.status == .pending ? T.dim : T.text)
                                    if !s.detail.isEmpty { Text(s.detail).font(T.mono(10)).foregroundStyle(s.status == .failed ? T.red : T.dim) }
                                }
                                Spacer()
                                Text(s.status.rawValue.uppercased()).font(T.mono(9)).foregroundStyle(color(s.status))
                            }.padding(.vertical, 6)
                        }
                    }.frame(maxWidth: 560)

                    VStack(alignment: .leading, spacing: 6) {
                        Button { withAnimation { ui.showLogs.toggle() } } label: {
                            Text(ui.showLogs ? "▾ LOG" : "▸ LOG").font(T.mono(11, .medium)).foregroundStyle(T.dim)
                        }.buttonStyle(.plain)
                        if ui.showLogs {
                            ScrollViewReader { p in
                                ScrollView {
                                    Text(engine.logs.joined(separator: "\n")).font(T.mono(10)).foregroundStyle(T.dim)
                                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).id("end")
                                }.frame(height: 180).padding(8).background(T.panel).overlay(Rectangle().stroke(T.line))
                                .onChange(of: engine.logs.count) { _, _ in p.scrollTo("end", anchor: .bottom) }
                            }
                        }
                    }.frame(maxWidth: 560)

                    HStack(spacing: 12) {
                        if engine.isRunning { PixelButton(title: "CANCEL") { engine.cancel() } }
                        else {
                            if engine.error != nil || engine.orbState == .error {
                                PixelButton(title: "RETRY", primary: true) { if let c = m.config { m.beginSetup(c) } }
                            }
                            PixelButton(title: "← BACK") { m.backToBuilder() }
                        }
                    }.padding(.top, 6)
                }.padding(.vertical, 20).padding(.bottom, 30).frame(maxWidth: .infinity)
            }
        }
    }

    func color(_ s: StepStatus) -> Color {
        switch s { case .done: return T.green; case .running: return T.amber; case .failed: return T.red; default: return T.dim }
    }
    @ViewBuilder func icon(_ s: StepStatus) -> some View {
        switch s {
        case .done: Text("■").foregroundStyle(T.green).font(T.mono(11))
        case .running: ProgressView().controlSize(.mini).tint(T.amber)
        case .failed: Text("✕").foregroundStyle(T.red).font(T.mono(11, .bold))
        case .skipped: Text("–").foregroundStyle(T.dim).font(T.mono(11))
        case .pending: Text("□").foregroundStyle(T.dim).font(T.mono(11))
        }
    }
}
