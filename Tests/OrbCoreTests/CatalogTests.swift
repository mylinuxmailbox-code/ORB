import Foundation
import Testing
@testable import OrbCore

@Suite struct CatalogTests {
    @Test func testHardware() async {
        let hw = await HardwareDetector().detect()
        #expect(hw.memoryGB > 1)
        #expect(hw.totalCores > 0)
        #expect(!hw.chip.isEmpty)
        #expect(HardwareDetector.parseGeneration("Apple M3 Pro") == 3)
        #expect(HardwareDetector.parseGeneration("Intel(R) Core(TM) i7") == 0)
    }

    @Test func testRegistry() async {
        let r = CompatibilityRegistry()
        #expect(!r.entries(kind: .stt).isEmpty)
        #expect(r.entries(kind: .tts).allSatisfy { $0.filePaths.count == 2 && $0.backend == .piper })
        #expect(r.entry(id: "stt:ggerganov/whisper.cpp#ggml-tiny.en") != nil)
        let h = r.heuristicModels(kind: .stt, repo: "x/y", files: [ModelFile(path: "ggml-foo.bin", sizeBytes: 5)], summary: nil)
        #expect(h.first?.compatibility == .experimental)
        let hw = HardwareProfile(chip: "Apple M2", isAppleSilicon: true, generation: 2, performanceCores: 4, totalCores: 8,
                                 gpuCores: 10, memoryGB: 16, osVersion: "", freeDiskGB: 100, tier: .standard)
        for k in ModelKind.allCases {
            let rec = await ModelCatalog().recommended(kind: k, hardware: hw)
            #expect(rec != nil)
        }
    }

    @Test func testCustomLocalModels() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("orb-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let binURL = tmp.appendingPathComponent("custom-whisper.en.bin")
        try Data(repeating: 0x42, count: 4096).write(to: binURL)
        let stt = try CompatibilityRegistry.customSTTFromLocalFile(binURL)
        #expect(stt.kind == .stt)
        #expect(stt.backend == .whispercpp)
        #expect(ModelDownloader().isDownloaded(stt))

        let onnxURL = tmp.appendingPathComponent("en_US-custom-medium.onnx")
        let jsonURL = tmp.appendingPathComponent("en_US-custom-medium.onnx.json")
        try Data(repeating: 0x01, count: 4096).write(to: onnxURL)
        try Data("{}".utf8).write(to: jsonURL)
        let tts = try CompatibilityRegistry.customTTSFromLocalFile(onnxURL)
        #expect(tts.kind == .tts)
        #expect(tts.backend == .piper)
        #expect(ModelDownloader().isDownloaded(tts))

        let llm = CompatibilityRegistry.customLLMFromTag("deepseek-r1:8b")
        #expect(llm.repoID == "deepseek-r1:8b")
    }
}
