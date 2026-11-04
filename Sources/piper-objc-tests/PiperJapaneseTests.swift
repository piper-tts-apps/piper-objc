import Testing
import Foundation
@testable import piper_objc

/// End-to-end tests for Japanese voices (`phoneme_type: "japanese"`).
/// The model and the OpenJTalk dictionary are downloaded once into the shared
/// test cache by `PiperTestAssets`.
@Suite("Piper Japanese Tests", .serialized)
struct PiperJapaneseTests {

    init() async throws {
        Bundle.setupSwizzling()
        try await PiperTestAssets.downloadJapaneseIfNeeded()
    }

    @Test("Synthesizes Japanese with an explicit OpenJTalk dictionary directory")
    func explicitDictionaryDirectory() async throws {
        let options = PiperCreateOptions(
            modelPath: PiperTestAssets.japaneseModelPath,
            configPath: PiperTestAssets.japaneseConfigPath,
            openjtalkDictDir: PiperTestAssets.openJTalkDictionaryDirectory.path
        )
        let piper = try Piper(options: options)
        let stats = try await PiperTestAssets.synthesizeStats(
            piper: piper, text: "今日は良い天気です。", fileName: "ja_explicit.wav")
        #expect(piper.status == .completed)
        #expect(stats.sampleCount > 10_000, "Expected real speech, got \(stats.sampleCount) samples")
        #expect(stats.rms > 0.01, "Expected non-silent audio, RMS was \(stats.rms)")
        #expect(stats.maxAbs > 0.05, "Expected non-silent audio, peak was \(stats.maxAbs)")
    }

    @Test("Synthesizes Japanese when the dictionary is discovered next to the model")
    func dictionaryDiscoveredNextToModel() async throws {
        let modelFolder = try isolatedModelFolder(withDictionary: true)
        defer { try? FileManager.default.removeItem(at: modelFolder) }
        let options = PiperCreateOptions(
            modelPath: modelFolder.appendingPathComponent("model.onnx").path,
            configPath: modelFolder.appendingPathComponent("model.onnx.json").path
        )
        let piper = try Piper(options: options)
        let stats = try await PiperTestAssets.synthesizeStats(
            piper: piper, text: "今日は良い天気です。", fileName: "ja_discovery.wav")
        #expect(piper.status == .completed)
        #expect(stats.sampleCount > 10_000, "Expected real speech, got \(stats.sampleCount) samples")
        #expect(stats.rms > 0.01, "Expected non-silent audio, RMS was \(stats.rms)")
        #expect(stats.maxAbs > 0.05, "Expected non-silent audio, peak was \(stats.maxAbs)")
    }

    @Test("Creation fails when no OpenJTalk dictionary is available")
    func creationFailsWithoutDictionary() throws {
        // Regression test for piper-app issue #74: a Japanese voice without a
        // dictionary must fail creation, not silently synthesize nothing.
        let modelFolder = try isolatedModelFolder(withDictionary: false)
        defer { try? FileManager.default.removeItem(at: modelFolder) }
        let options = PiperCreateOptions(
            modelPath: modelFolder.appendingPathComponent("model.onnx").path,
            configPath: modelFolder.appendingPathComponent("model.onnx.json").path
        )
        #expect(throws: (any Error).self) {
            _ = try Piper(options: options)
        }
    }

    /// Copies the Japanese model into a fresh folder so a test controls exactly
    /// what sits next to it (an `openjtalk` subfolder, or nothing).
    private func isolatedModelFolder(withDictionary: Bool) throws -> URL {
        let fileManager = FileManager.default
        let folder = fileManager.temporaryDirectory
            .appendingPathComponent("piper_ja_\(UUID().uuidString)")
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        try fileManager.copyItem(at: URL(fileURLWithPath: PiperTestAssets.japaneseModelPath),
                                 to: folder.appendingPathComponent("model.onnx"))
        try fileManager.copyItem(at: URL(fileURLWithPath: PiperTestAssets.japaneseConfigPath),
                                 to: folder.appendingPathComponent("model.onnx.json"))
        if withDictionary {
            try fileManager.copyItem(at: PiperTestAssets.openJTalkDictionaryDirectory,
                                     to: folder.appendingPathComponent("openjtalk"))
        }
        return folder
    }
}
