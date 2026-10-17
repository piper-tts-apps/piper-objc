import Testing
import Foundation
@testable import piper_objc

/// End-to-end tests for Chinese voices (`phoneme_type: "pinyin"`).
/// Mirrors the libpiper C++ PinyinTest semantics: direct pinyin input always
/// works, Hanzi input goes through the G2PW / cppinyin dictionaries, and a
/// missing G2PW directory degrades gracefully instead of failing creation
/// (libpiper treats the dictionary load as non-fatal, unlike Japanese).
@Suite("Piper Chinese Tests", .serialized)
struct PiperChineseTests {

    init() async throws {
        Bundle.setupSwizzling()
        try await PiperTestAssets.downloadChineseIfNeeded()
    }

    @Test("Synthesizes direct pinyin with a G2PW dictionary directory")
    func pinyinWithDictionary() async throws {
        let piper = try makePiper(g2pwModelDir: PiperTestAssets.g2pwDirectory.path)
        let stats = try await PiperTestAssets.synthesizeStats(
            piper: piper, text: "ni3 hao3", fileName: "zh_pinyin.wav")
        #expect(piper.status == .completed)
        #expect(stats.sampleCount > 1_000, "Expected real speech, got \(stats.sampleCount) samples")
        #expect(stats.maxAbs > 0.01, "Expected non-silent audio, peak was \(stats.maxAbs)")
    }

    @Test("Synthesizes Hanzi through the dictionary fallback")
    func hanziWithDictionary() async throws {
        let piper = try makePiper(g2pwModelDir: PiperTestAssets.g2pwDirectory.path)
        // 你我 (ni3 wo3): both characters are monophonic, same phrase the
        // libpiper C++ HanziMonoFallback test uses.
        let stats = try await PiperTestAssets.synthesizeStats(
            piper: piper, text: "你我", fileName: "zh_hanzi.wav")
        #expect(piper.status == .completed)
        #expect(stats.sampleCount > 1_000, "Expected real speech, got \(stats.sampleCount) samples")
        #expect(stats.maxAbs > 0.01, "Expected non-silent audio, peak was \(stats.maxAbs)")
    }

    @Test("Creation succeeds without G2PW data and direct pinyin still synthesizes")
    func missingDictionaryDegradesToPinyin() async throws {
        let missingDir = PiperTestAssets.cacheDirectory.appendingPathComponent("g2pw_missing").path
        let piper = try makePiper(g2pwModelDir: missingDir)
        let stats = try await PiperTestAssets.synthesizeStats(
            piper: piper, text: "ni3 hao3", fileName: "zh_pinyin_no_dict.wav")
        #expect(piper.status == .completed)
        #expect(stats.sampleCount > 1_000, "Expected real speech, got \(stats.sampleCount) samples")
        #expect(stats.maxAbs > 0.01, "Expected non-silent audio, peak was \(stats.maxAbs)")
    }

    private func makePiper(g2pwModelDir: String?) throws -> Piper {
        let options = PiperCreateOptions(
            modelPath: PiperTestAssets.chineseModelPath,
            configPath: PiperTestAssets.chineseConfigPath,
            g2pwModelDir: g2pwModelDir
        )
        return try Piper(options: options)
    }
}
