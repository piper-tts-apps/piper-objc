import CryptoKit
import Foundation
import piper_objc

extension Bundle {
    static var isSetupSwizzling = false
    static func setupSwizzling() {
        if Bundle.isSetupSwizzling {
            return
        }
        Bundle.isSetupSwizzling = true
        let originalSelector = #selector(Bundle.url(forResource:withExtension:))
        let swizzledSelector = #selector(swizzled_url(forResource:withExtension:))

        guard let originalMethod = class_getInstanceMethod(Bundle.self, originalSelector),
              let swizzledMethod = class_getInstanceMethod(Bundle.self, swizzledSelector) else { return }

        method_exchangeImplementations(originalMethod, swizzledMethod)
    }

    @objc func swizzled_url(forResource name: String?, withExtension ext: String?) -> URL? {
        // The internal Piper code likely searches for "espeak-ng_data" or "espeak-ng-data"
        if (name == "espeak-ng_data" || name == "espeak-ng-data") && ext == "bundle" {
            // Check common SPM resource bundle naming conventions
            let candidates = [
                "espeak-ng-spm_espeak-ng-data.bundle",
                "espeak-ng_data.bundle",
                "piper-objc_espeak-ng-data.bundle"
            ]
            
            let testBundleURL = Bundle(for: PiperTestAssets.self).bundleURL
            let searchPaths = [
                testBundleURL, // Inside the test bundle
                testBundleURL.deletingLastPathComponent(), // Alongside the test bundle
                testBundleURL.deletingLastPathComponent().deletingLastPathComponent() // One level up
            ]

            for searchURL in searchPaths {
                for candidate in candidates {
                    let bundleURL = searchURL.appendingPathComponent(candidate)
                    if FileManager.default.fileExists(atPath: bundleURL.path) {
                        return bundleURL
                    }
                }
            }
        }
        let originalResult = self.swizzled_url(forResource: name, withExtension: ext)
        return originalResult
    }
}

class PiperTestAssets {
    static let modelBase = "https://huggingface.co/IhorShevchuk/piper1-voices-fp16-quantized/resolve/main"
    static let modelSubPath  = "en/en_US/amy/medium"
    static let modelName = "en_US-amy-medium.onnx"
    static let modelURL = URL(string: "\(modelBase)/\(modelSubPath)/\(modelName)")!
    static let configURL =  URL(string: "\(modelBase)/\(modelSubPath)/\(modelName).json")!

    static var cacheDirectory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("piper_test_assets")
    }

    static var modelPath: String {
        cacheDirectory.appendingPathComponent("model.onnx").path
    }

    static var configPath: String {
        cacheDirectory.appendingPathComponent("model.onnx.json").path
    }

    static var espeakNGDataPath: String {
        // Return empty string to trigger internal automatic installation.
        // Swizzling handles finding the bundle in the test environment.
        return ""
    }

    /// Ensures models are downloaded and returns true if successful
    static func downloadIfNeeded() async throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: cacheDirectory.path) {
            try fm.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        }

        try await downloadFile(from: modelURL, to: URL(fileURLWithPath: modelPath))
        try await downloadFile(from: configURL, to: URL(fileURLWithPath: configPath))
    }

    private static func downloadFile(from url: URL, to destination: URL) async throws {
        if FileManager.default.fileExists(atPath: destination.path) {
            return
        }

        print("Downloading test asset from \(url.lastPathComponent)...")
        let (tempURL, response) = try await URLSession.shared.download(from: url)
        
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw NSError(domain: "PiperTestAssets", code: 0, userInfo: [NSLocalizedDescriptionKey: "Failed to download asset"])
        }

        try FileManager.default.moveItem(at: tempURL, to: destination)
    }

    // MARK: - Japanese assets

    static let japaneseModelSubPath = "ja/ja_JA/hi_fi_captain/medium"
    static let japaneseModelName = "ja_JA-hi_fi_captain-medium.onnx"
    static let japaneseModelURL = URL(string: "\(modelBase)/\(japaneseModelSubPath)/\(japaneseModelName)")!
    static let japaneseConfigURL = URL(string: "\(modelBase)/\(japaneseModelSubPath)/\(japaneseModelName).json")!

    static var japaneseModelDirectory: URL {
        cacheDirectory.appendingPathComponent("ja_model")
    }

    static var japaneseModelPath: String {
        japaneseModelDirectory.appendingPathComponent("model.onnx").path
    }

    static var japaneseConfigPath: String {
        japaneseModelDirectory.appendingPathComponent("model.onnx.json").path
    }

    /// Canonical OpenJTalk dictionary archive (the pyopenjtalk-plus dictionary
    /// the Japanese voices were trained with), hash-pinned like the app does.
    static let openJTalkZipURL = URL(
        string: "https://huggingface.co/IhorShevchuk/openjtalk-dictionary/resolve/main/openjtalk.zip")!
    static let openJTalkZipSHA256 = "06039fe6f628cb7d946284d81aaca911380f90d880f81c768f0c7d06be557322"
    static let openJTalkRequiredFiles = ["sys.dic", "matrix.bin", "char.bin", "unk.dic"]

    static var openJTalkDictionaryDirectory: URL {
        cacheDirectory.appendingPathComponent("openjtalk")
    }

    static func downloadJapaneseIfNeeded() async throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: japaneseModelDirectory, withIntermediateDirectories: true)
        try await downloadFile(from: japaneseModelURL, to: URL(fileURLWithPath: japaneseModelPath))
        try await downloadFile(from: japaneseConfigURL, to: URL(fileURLWithPath: japaneseConfigPath))
        try await downloadOpenJTalkDictionaryIfNeeded()
    }

    private static func downloadOpenJTalkDictionaryIfNeeded() async throws {
        let fileManager = FileManager.default
        let isInstalled = openJTalkRequiredFiles.allSatisfy {
            fileManager.fileExists(atPath: openJTalkDictionaryDirectory.appendingPathComponent($0).path)
        }
        if isInstalled {
            return
        }
        let zipURL = try await verifiedOpenJTalkZip()
        try fileManager.createDirectory(at: openJTalkDictionaryDirectory, withIntermediateDirectories: true)
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        unzip.arguments = ["-o", "-q", zipURL.path, "-d", openJTalkDictionaryDirectory.path]
        try unzip.run()
        unzip.waitUntilExit()
        let unpacked = unzip.terminationStatus == 0 && openJTalkRequiredFiles.allSatisfy {
            fileManager.fileExists(atPath: openJTalkDictionaryDirectory.appendingPathComponent($0).path)
        }
        guard unpacked else {
            throw NSError(domain: "PiperTestAssets", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "Failed to unpack OpenJTalk dictionary"])
        }
    }

    /// Downloads the dictionary archive and verifies its SHA-256 before use.
    /// A stale or corrupt cached archive is dropped and re-downloaded once.
    private static func verifiedOpenJTalkZip() async throws -> URL {
        let zipURL = cacheDirectory.appendingPathComponent("openjtalk.zip")
        for attempt in 0..<2 {
            if !FileManager.default.fileExists(atPath: zipURL.path) {
                try await downloadFile(from: openJTalkZipURL, to: zipURL)
            }
            let data = try Data(contentsOf: zipURL)
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            if digest == openJTalkZipSHA256 {
                return zipURL
            }
            try? FileManager.default.removeItem(at: zipURL)
            if attempt == 1 {
                throw NSError(domain: "PiperTestAssets", code: 2,
                              userInfo: [NSLocalizedDescriptionKey: "OpenJTalk zip SHA-256 mismatch: \(digest)"])
            }
        }
        return zipURL
    }

    // MARK: - Chinese assets

    static let chineseModelSubPath = "zh/zh_CN/chaowen/medium"
    static let chineseModelName = "zh_CN-chaowen-medium.onnx"
    static let chineseModelURL = URL(string: "\(modelBase)/\(chineseModelSubPath)/\(chineseModelName)")!
    static let chineseConfigURL = URL(string: "\(modelBase)/\(chineseModelSubPath)/\(chineseModelName).json")!

    static var chineseModelDirectory: URL {
        cacheDirectory.appendingPathComponent("zh_model")
    }

    static var chineseModelPath: String {
        chineseModelDirectory.appendingPathComponent("model.onnx").path
    }

    static var chineseConfigPath: String {
        chineseModelDirectory.appendingPathComponent("model.onnx.json").path
    }

    /// G2PW / cppinyin dictionary files, taken from the same dataset files the
    /// app bundles (PiperApp/Resources/G2PW.xcassets in piper-app-apple).
    static let g2pwFiles: [(name: String, remotePath: String)] = [
        ("MONOPHONIC_CHARS.txt", "MONOPHONIC_CHARS.dataset/MONOPHONIC_CHARS.txt"),
        ("char_bopomofo_dict.json", "char_bopomofo_dict.dataset/char_bopomofo_dict.json"),
        ("bopomofo_to_pinyin_wo_tune_dict.json",
         "bopomofo_to_pinyin_wo_tune_dict.dataset/bopomofo_to_pinyin_wo_tune_dict.json")
    ]
    static let g2pwBaseURLs = [
        "https://raw.githubusercontent.com/piper-tts-apps/piper-app-apple/main/PiperApp/Resources/G2PW.xcassets",
        "https://cdn.jsdelivr.net/gh/piper-tts-apps/piper-app-apple@main/PiperApp/Resources/G2PW.xcassets"
    ]

    static var g2pwDirectory: URL {
        cacheDirectory.appendingPathComponent("g2pw")
    }

    static func downloadChineseIfNeeded() async throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: chineseModelDirectory, withIntermediateDirectories: true)
        try await downloadFile(from: chineseModelURL, to: URL(fileURLWithPath: chineseModelPath))
        try await downloadFile(from: chineseConfigURL, to: URL(fileURLWithPath: chineseConfigPath))
        try fileManager.createDirectory(at: g2pwDirectory, withIntermediateDirectories: true)
        for file in g2pwFiles {
            let destination = g2pwDirectory.appendingPathComponent(file.name)
            if fileManager.fileExists(atPath: destination.path) {
                continue
            }
            var lastError: Error?
            var downloaded = false
            for base in g2pwBaseURLs where !downloaded {
                do {
                    try await downloadFile(from: URL(string: "\(base)/\(file.remotePath)")!, to: destination)
                    downloaded = true
                } catch {
                    lastError = error
                }
            }
            guard downloaded else {
                throw lastError ?? NSError(
                    domain: "PiperTestAssets", code: 4,
                    userInfo: [NSLocalizedDescriptionKey: "Failed to download G2PW file \(file.name)"])
            }
        }
    }

    // MARK: - WAV inspection

    struct WavFileStats {
        let sampleCount: Int
        let rms: Double
        let maxAbs: Double
    }

    /// Synthesizes text to a temporary WAV file and returns stats for its samples.
    static func synthesizeStats(piper: Piper, text: String, fileName: String) async throws -> WavFileStats {
        let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        try? FileManager.default.removeItem(at: outputURL)
        await withCheckedContinuation { continuation in
            piper.synthesize(text, toFileAtPath: outputURL.path) {
                continuation.resume()
            }
        }
        let stats = try wavStats(atPath: outputURL.path)
        print("Synthesized \(fileName): \(stats.sampleCount) samples, RMS \(stats.rms), peak \(stats.maxAbs)")
        try? FileManager.default.removeItem(at: outputURL)
        return stats
    }

    /// Sample stats for the float32 mono WAV files written by Piper.
    static func wavStats(atPath path: String) throws -> WavFileStats {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let headerSize = 44 // canonical header written by Piper's WAV writer
        guard data.count > headerSize else {
            return WavFileStats(sampleCount: 0, rms: 0, maxAbs: 0)
        }
        let sampleBytes = data.subdata(in: headerSize..<data.count)
        let count = sampleBytes.count / MemoryLayout<Float>.size
        var sumOfSquares = 0.0
        var peak = 0.0
        sampleBytes.withUnsafeBytes { rawBuffer in
            let floats = rawBuffer.bindMemory(to: Float.self)
            for index in 0..<count {
                let value = Double(floats[index])
                sumOfSquares += value * value
                peak = max(peak, abs(value))
            }
        }
        let rms = count > 0 ? (sumOfSquares / Double(count)).squareRoot() : 0
        return WavFileStats(sampleCount: count, rms: rms, maxAbs: peak)
    }
}
