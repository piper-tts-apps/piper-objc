import Testing
import Foundation
@testable import piper_objc

/// Regression tests for the process-global espeak-ng race behind the
/// PiperTTS 1.0.16 (340) macOS crashes of Oct 25, 2026 and the piper-objc
/// PR #18 CI crash: two Piper instances in one process, one synthesizing
/// while the other frees/recreates its synthesizer (piper_free ->
/// espeak_Terminate frees process-global phoneme/voice data).
/// Mirrors the piper-kotlin PR #2 scenario (process-wide session lock).
@Suite("Piper Concurrent Instance Race Tests", .serialized)
struct PiperConcurrencyRaceTests {

    init() async throws {
        Bundle.setupSwizzling()
        try await PiperTestAssets.downloadIfNeeded()
    }

    private func makePiper() throws -> Piper {
        return try Piper(
            modelPath: PiperTestAssets.modelPath,
            configPath: PiperTestAssets.configPath,
            espeakNGData: PiperTestAssets.espeakNGDataPath
        )
    }

    @Test("Instance recreating its synthesizer must not corrupt another instance's synthesis")
    func recreateRacingSynthesis() async throws {
        let synthesizing = try makePiper()
        let recreating = try makePiper()
        // Recreate (piper_free + piper_create) before every sentence.
        recreating.memoryThresholdBytes = 1

        let text = """
            The quick brown fox jumps over the lazy dog. \
            Pack my box with five dozen liquor jugs. \
            How vexingly quick daft zebras jump! \
            Bright vixens jump; dozy fowl quack.
            """

        let dir = FileManager.default.temporaryDirectory
        let outA = dir.appendingPathComponent("race_synth.wav").path
        let outB = dir.appendingPathComponent("race_recreate.wav").path

        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                for _ in 0..<8 {
                    await synthesizing.synthesize(text, toFileAtPath: outA)
                }
            }
            group.addTask {
                for _ in 0..<8 {
                    await recreating.synthesize(text, toFileAtPath: outB)
                }
            }
        }

        for path in [outA, outB] {
            #expect(FileManager.default.fileExists(atPath: path), "Missing output \(path)")
            let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int64 ?? 0
            #expect(size > 4096, "Output suspiciously small (\(size) bytes): \(path)")
            try? FileManager.default.removeItem(atPath: path)
        }
        #expect(synthesizing.status != .error)
        #expect(recreating.status != .error)
    }

    @Test("Two instances synthesizing concurrently must not corrupt each other")
    func concurrentSynthesis() async throws {
        let first = try makePiper()
        let second = try makePiper()

        let text = "Concurrent synthesis must stay safe. Every sentence exercises the shared phoneme tables."
        let dir = FileManager.default.temporaryDirectory
        let outA = dir.appendingPathComponent("race_conc_a.wav").path
        let outB = dir.appendingPathComponent("race_conc_b.wav").path

        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                for _ in 0..<8 {
                    await first.synthesize(text, toFileAtPath: outA)
                }
            }
            group.addTask {
                for _ in 0..<8 {
                    await second.synthesize(text, toFileAtPath: outB)
                }
            }
        }

        for path in [outA, outB] {
            let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int64 ?? 0
            #expect(size > 4096, "Output suspiciously small (\(size) bytes): \(path)")
            try? FileManager.default.removeItem(atPath: path)
        }
    }
}
